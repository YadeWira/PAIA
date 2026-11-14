/* paiapix.c - the pixel model's hot loop, in C.

   The same model as TPixelModel.CodePixels in paiamodel.pas, operation for
   operation, in integers: the two have to give the same bytes, and the test
   suite checks that they do (the checked build is Pascal only). Pascal owns
   every table and hands them over in TPixState; the arithmetic coder's
   state comes in TCState and goes back after each batch of pixels. No libc:
   nothing is allocated here, and the output buffer has room for the batch
   (the caller makes sure).

   Keep it in step with paiamodel.pas and paiaarith.pas. */

#include <stdint.h>

#define PIXEL_CONTEXTS 36
#define FLAG_CONTEXTS 7
#define MATCH_MIN 6
#define NONE 256

typedef struct {
  uint32_t *e;
  int64_t mask;
  int32_t limit;
  int32_t pad;
} Counters;

typedef struct {
  int32_t *w;
  int32_t nIn, rate, shift, pad;
} Mixer;

typedef struct {
  int32_t *t;
  int32_t rate, pad;
} Apm;

typedef struct {
  Counters t[PIXEL_CONTEXTS];
  Counters ft[FLAG_CONTEXTS];
  Mixer mx, mx2, mx3, mf, fmx;
  Apm apm1, apm2, fapm;
  const int16_t *stretchTab;
  const int16_t *squashTab;
  const int32_t *apmBase;
  const int32_t *rateTab;
} TPixState;

typedef struct {
  int32_t encoding;
  uint32_t x1, x2, x;
  uint8_t *buf;
  int64_t n;     /* encoder: bytes written */
  int64_t p;     /* decoder: next byte */
  int64_t last;  /* decoder: end of the data */
} TCState;

static inline uint64_t hash(uint64_t a, uint64_t b) {
  uint64_t r = ((a + 1) * UINT64_C(0x9E3779B1)) & 0xFFFFFFFFu;
  r = ((r ^ b) * UINT64_C(0x85EBCA6B)) & 0xFFFFFFFFu;
  return r ^ (r >> 15);
}

/* ---- coder ---- */

static inline int code(TCState *c, int bit, int p12) {
  uint32_t xmid;
  if (p12 < 1) p12 = 1; else if (p12 > 4095) p12 = 4095;
  xmid = c->x1 + (uint32_t)(((uint64_t)(c->x2 - c->x1) * (uint32_t)p12) >> 12);
  if (c->encoding) {
    if (bit) c->x2 = xmid; else c->x1 = xmid + 1;
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
      c->buf[c->n++] = (uint8_t)(c->x2 >> 24);
      c->x1 <<= 8;
      c->x2 = (c->x2 << 8) | 255;
    }
    return bit;
  } else {
    if (c->x <= xmid) { bit = 1; c->x2 = xmid; } else { bit = 0; c->x1 = xmid + 1; }
    while (((c->x1 ^ c->x2) & 0xFF000000u) == 0) {
      c->x1 <<= 8;
      c->x2 = (c->x2 << 8) | 255;
      c->x <<= 8;
      if (c->p < c->last) c->x |= c->buf[c->p++];
    }
    return bit;
  }
}

/* ---- counters, mixer, APM ---- */

static inline int squash(const TPixState *s, int x) {
  if (x > 2047) return 4095;
  if (x < -2047) return 1;
  return s->squashTab[x + 2048];
}

static inline int p12(const Counters *t, int64_t i) {
  return (int)(((t->e[i] >> 16) ^ 0x8000u) >> 4);
}

static inline void update(const TPixState *s, const Counters *t, int64_t i, int bit) {
  uint32_t x = t->e[i];
  int32_t c = (int32_t)(x & 0xFFFF);
  int32_t v = (int32_t)((x >> 16) ^ 0x8000u);
  if (bit) v = v + (int32_t)(((uint32_t)(65535 - v) * (uint32_t)s->rateTab[c]) >> 16);
  else v = v - (int32_t)(((uint32_t)v * (uint32_t)s->rateTab[c]) >> 16);
  if (v < 32) v = 32; else if (v > 65503) v = 65503;
  if (c < t->limit) c++;
  t->e[i] = ((uint32_t)(v ^ 0x8000) << 16) | (uint32_t)c;
}

static inline int mix(const TPixState *s, const Mixer *m, const int32_t *x, int k, int ctx,
                      int32_t **wsel) {
  int64_t dot = 0;
  int32_t *w = m->w + (int64_t)ctx * m->nIn;
  int i;
  for (i = 0; i < k; i++) dot += (int64_t)x[i] * w[i];
  dot >>= 16;   /* arithmetic, as SarInt64 */
  if (dot > 2047) dot = 2047; else if (dot < -2047) dot = -2047;
  *wsel = w;
  return squash(s, (int)dot);
}

static inline void mix_update(const Mixer *m, const int32_t *x, int k, int32_t *w, int pr, int bit) {
  int32_t err = ((bit << 12) - pr) * m->rate;
  int i;
  for (i = 0; i < k; i++) {
    int32_t v = w[i] + ((x[i] * err) >> m->shift);
    if (v > 16777216) v = 16777216; else if (v < -16777216) v = -16777216;
    w[i] = v;
  }
}

typedef struct { int64_t idx; int bucket; } ApmPos;

static inline int apm_refine(const TPixState *s, const Apm *a, int p, int64_t ctx, ApmPos *pos) {
  int st = s->stretchTab[p] + 2048;
  int w = st & 127;
  int b = st >> 7;
  int64_t idx = ctx * 33 + b;
  int r = (int)(((int64_t)(a->t[idx] + s->apmBase[b]) * (128 - w)
               + (int64_t)(a->t[idx + 1] + s->apmBase[b + 1]) * w) >> 11);
  if (w >= 64) { idx++; b++; }
  pos->idx = idx; pos->bucket = b;
  if (r < 1) r = 1; else if (r > 4095) r = 4095;
  return r;
}

static inline void apm_update(const TPixState *s, const Apm *a, const ApmPos *pos, int bit) {
  int32_t g = (bit << 16) + (bit << a->rate) - bit - bit;
  int32_t v = a->t[pos->idx] + s->apmBase[pos->bucket];
  a->t[pos->idx] += (g - v) >> a->rate;
}

/* ---- the pixels ---- */

typedef struct {
  int32_t run, cntT, cntV, mLen, mPtr, mMask, perX, perY;
  int32_t *mt;   /* the match's table, mMask + 1 entries */
} TRun;

/* x0, y0: where px[i0] is (the caller divides: no 64-bit division here,
   which 32-bit targets would take from a runtime library) */
void paia_code_pixels(TPixState *s, TCState *cd, uint8_t *px, int64_t i0, int64_t i1,
                      int64_t n, int64_t width, int32_t bits, const uint16_t *cv,
                      const uint16_t *pw, int32_t transp, TRun *r, int64_t x0, int64_t y0) {
  int64_t i, w = width, slot[PIXEL_CONTEXTS], fidx[FLAG_CONTEXTS];
  uint64_t base[PIXEL_CONTEXTS];
  int32_t xin[PIXEL_CONTEXTS + 1], fin[FLAG_CONTEXTS + 1], min4[4];
  int run = r->run, cntT = r->cntT, cntV = r->cntV;
  int32_t mLen = r->mLen, mPtr = r->mPtr, mMask = r->mMask, perX = r->perX, perY = r->perY;
  int32_t *mt = r->mt;
  int iw = (int)width;
  int j;
  for (j = 0; j < PIXEL_CONTEXTS; j++) slot[j] = 0;
  int64_t x = x0 - 1, y = y0;
#define P(dx, dy) ((x + (dx) < 0 || x + (dx) >= width || y < (dy)) ? NONE : px[i + (dx) - (int64_t)(dy) * w])
  for (i = i0; i < i1; i++) {
    int L, U, UL, UR, LL, UU, PV, PR, PD, PW, cand, pat, v, node, sub, bit, b, bp, pm, pa, pb, p2, p3,
        pr12, sel, MP, lb;
    int NWW, NEE, NNWW, NNEE, NNW, NNE, WWW, NEEE, NEEEE, TX, TY, c0, c1;
    int32_t *wsel, *wsel2, *wsel3, *wself;
    ApmPos ap1, ap2;
    if (++x == w) { x = 0; y++; }

    /* the match: after the pixel before, still going, or found again from
       the last MATCH_MIN pixels (and how long it really is, up to 32) */
    if (i > 0) {
      if (mLen > 0) {
        if (px[mPtr] == px[i - 1]) { mLen++; mPtr++; } else mLen = 0;
      }
      if (i >= MATCH_MIN) {
        int64_t mh = (int64_t)(hash(hash((uint64_t)px[i - 1] * 256 + px[i - 2],
                                         (uint64_t)px[i - 3] * 256 + px[i - 4]),
                                    (uint64_t)px[i - 5] * 256 + px[i - 6]) & (uint64_t)(uint32_t)mMask);
        if (mLen == 0 && mt[mh] > 0) {
          mPtr = mt[mh];
          while (mLen < 32 && mPtr - mLen - 1 >= 0 && px[mPtr - mLen - 1] == px[i - mLen - 1]) mLen++;
          if (mLen < MATCH_MIN) mLen = 0;
        }
        mt[mh] = (int32_t)i;
      }
    }
    MP = mLen > 0 ? px[mPtr] : NONE;
    if (mLen == 0) lb = 0; else if (mLen < 8) lb = 1; else if (mLen < 12) lb = 2;
    else if (mLen < 16) lb = 3; else if (mLen < 24) lb = 4; else if (mLen < 32) lb = 5;
    else lb = 6;

    L = x > 0 ? px[i - 1] : NONE;
    LL = x > 1 ? px[i - 2] : NONE;
    if (y > 0) {
      U = px[i - w];
      UL = x > 0 ? px[i - w - 1] : NONE;
      UR = x + 1 < width ? px[i - w + 1] : NONE;
    } else { U = NONE; UL = NONE; UR = NONE; }
    UU = y > 1 ? px[i - 2 * w] : NONE;
    if (cv) {
      PV = cv[i];
      PR = (x + 1 < width && i + 1 < n) ? cv[i + 1] : NONE;
      PD = (i + w < n) ? cv[i + w] : NONE;
    } else { PV = NONE; PR = NONE; PD = NONE; }
    PW = pw ? pw[i] : NONE;
    if (PV != NONE) cand = (transp >= 0 && cntT >= cntV) ? transp : PV;
    else if (L != NONE) cand = L;
    else if (U != NONE) cand = U;
    else cand = 0;

    v = cd->encoding ? px[i] : 0;

    /* the flag */
    pat = (cand == L) + 2 * (cand == U) + 4 * (cand == UL) + 8 * (cand == UR)
        + 16 * (cand == PR) + 32 * (cand == PD) + 64 * (L == U) + 128 * (PV != NONE)
        + 256 * (cand == LL) + 512 * (cand == UU)
        + 1024 * (PW == 257) + 2048 * (transp >= 0 && cand == transp);
    fidx[0] = pat & s->ft[0].mask;
    fidx[1] = (int64_t)hash(pat, run) & s->ft[1].mask;
    fidx[2] = (int64_t)hash(hash(L * 512 + U, cand), 11) & s->ft[2].mask;
    fidx[3] = (int64_t)hash(hash(PV * 512 + PR, PD * 512 + L), 12 + PW * 16) & s->ft[3].mask;
    fidx[4] = (int64_t)hash(hash(L * 512 + U, UL * 512 + UR), cand + 13 * 512) & s->ft[4].mask;
    fidx[5] = (int64_t)hash(hash(UU * 512 + LL, cand), pat + 14 * 2048) & s->ft[5].mask;
    fidx[6] = (int64_t)hash(hash((MP == cand) + 2 * (MP == NONE), lb), (pat & 63) + 15 * 2048)
              & s->ft[6].mask;
    for (j = 0; j < FLAG_CONTEXTS; j++) fin[j] = s->stretchTab[p12(&s->ft[j], fidx[j])];
    fin[FLAG_CONTEXTS] = 256;
    pm = mix(s, &s->fmx, fin, FLAG_CONTEXTS + 1, run * 4 + (pat & 3), &wsel);
    pa = apm_refine(s, &s->fapm, pm, (int64_t)(pat & 1023) * 16 + run, &ap1);
    pr12 = (pm + 3 * pa) / 4;
    bit = code(cd, v == cand, pr12);
    for (j = 0; j < FLAG_CONTEXTS; j++) update(s, &s->ft[j], fidx[j], bit);
    mix_update(&s->fmx, fin, FLAG_CONTEXTS + 1, wsel, pm, bit);
    apm_update(s, &s->fapm, &ap1, bit);
    if (bit) {
      if (run < 15) run++;
      px[i] = (uint8_t)cand;
      if (PV != NONE) {
        if (cand == transp) cntT++;
        if (cand == PV) cntV++;
      }
      continue;
    }
    run = 0;

    /* the pixel's bits are predicted from what is seen: a transparent
       neighbour shows the canvas under it */
    if (transp >= 0 && cv) {
      if (L == transp && cv[i - 1] != NONE) L = cv[i - 1];
      if (LL == transp && cv[i - 2] != NONE) LL = cv[i - 2];
      if (U == transp && cv[i - w] != NONE) U = cv[i - w];
      if (UL == transp && cv[i - w - 1] != NONE) UL = cv[i - w - 1];
      if (UR == transp && cv[i - w + 1] != NONE) UR = cv[i - w + 1];
      if (UU == transp && cv[i - 2 * w] != NONE) UU = cv[i - 2 * w];
    }
    /* farther ones, as they are */
    NWW = P(-2, 1); NEE = P(2, 1); NNWW = P(-2, 2); NNEE = P(2, 2);
    NNW = P(-1, 2); NNE = P(1, 2); WWW = P(-3, 0); NEEE = P(3, 1); NEEEE = P(4, 1);
    TX = perX > 0 ? P(-perX, 0) : NONE;
    TY = perY > 0 ? P(0, perY) : NONE;
    c0 = (int)x * 16 / iw; c1 = (int)x * 64 / iw;

    base[0] = (uint64_t)bits * 512 + (uint64_t)cand;
    base[1] = hash(L, 1);
    base[2] = hash(U, 2);
    base[3] = hash(L * 512 + U, 3);
    base[4] = hash(hash(L * 512 + U, UL * 512 + UR), 4);
    base[5] = hash(hash(L * 512 + LL, U * 512 + UU), 5);
    base[6] = hash(hash(PV, L * 512 + U), 6);
    base[7] = hash(hash(PV * 512 + PR, PD), 7 + PW * 16);
    base[8] = hash(hash(UL * 512 + U, UR), 8);
    base[9] = hash(hash(L, c0), 9);
    base[10] = hash(hash(U, c0), 10);
    base[11] = hash(hash(UL, c0), 11);
    base[12] = hash(hash(UR, c0), 12);
    base[13] = hash(NWW, 13);
    base[14] = hash(NEE, 14);
    base[15] = hash(LL, 15);
    base[16] = hash(UU, 16);
    base[17] = hash(hash(L, UR), 17);
    base[18] = hash(hash(U, UU), 18);
    base[19] = hash(hash(UL, NNWW), 19);
    base[20] = hash(hash(UR, NNEE), 20);
    base[21] = hash(hash(L, WWW), 21);
    base[22] = hash(hash(LL, NEE), 22);
    base[23] = hash(hash(L, NEEE), 23);
    base[24] = hash(hash(L, NEEEE), 24);
    base[25] = hash(hash(L * 512 + UR, NEE), 25);
    base[26] = hash(hash(U * 512 + UR, UU * 512 + NNE), 26);
    base[27] = hash(hash(U * 512 + UL, NNW * 512 + UU), 27);
    base[28] = hash(hash(L * 512 + LL, NWW * 512 + UL), 28);
    base[29] = hash(c0, 29);
    base[30] = hash(hash(U, c1), 30);
    base[31] = hash(hash(L, c1), 31);
    base[32] = hash(hash(MP, lb), 32);
    base[33] = hash(hash(MP * 512 + L, lb), 33);
    base[34] = hash(hash(TX, TY), 34);
    base[35] = hash(hash(TX * 512 + TY, L * 512 + U), 35);
    sel = (L == U) + 2 * (PV != NONE && PV == L) + 4 * (U == UR);
    node = 1; sub = 1;
    for (b = bits - 1; b >= 0; b--) {
      bp = bits - 1 - b;
      if (b == bits - 1 || b == 3) {
        for (j = 0; j < PIXEL_CONTEXTS; j++)
          slot[j] = (int64_t)((hash(base[j], node) << 4) & (uint64_t)s->t[j].mask);
        sub = 1;
      }
      for (j = 0; j < PIXEL_CONTEXTS; j++) xin[j] = s->stretchTab[p12(&s->t[j], slot[j] + sub)];
      xin[PIXEL_CONTEXTS] = 256;
      pm = mix(s, &s->mx, xin, PIXEL_CONTEXTS + 1, bp * 8 + sel, &wsel);
      p2 = mix(s, &s->mx2, xin, PIXEL_CONTEXTS + 1, node & 255, &wsel2);
      p3 = mix(s, &s->mx3, xin, PIXEL_CONTEXTS + 1, L * 8 + bp, &wsel3);
      min4[0] = s->stretchTab[pm]; min4[1] = s->stretchTab[p2]; min4[2] = s->stretchTab[p3];
      min4[3] = 256;
      pr12 = mix(s, &s->mf, min4, 4, bp * 7 + lb, &wself);
      pa = apm_refine(s, &s->apm1, pr12, (int64_t)(((L & 255) << 8) | (node & 255)), &ap1);
      pb = apm_refine(s, &s->apm2, pr12, (int64_t)(((U & 255) << 8) | (node & 255)), &ap2);
      bit = code(cd, (v >> b) & 1, (pr12 + pa + 2 * pb) / 4);
      for (j = 0; j < PIXEL_CONTEXTS; j++) update(s, &s->t[j], slot[j] + sub, bit);
      mix_update(&s->mx, xin, PIXEL_CONTEXTS + 1, wsel, pm, bit);
      mix_update(&s->mx2, xin, PIXEL_CONTEXTS + 1, wsel2, p2, bit);
      mix_update(&s->mx3, xin, PIXEL_CONTEXTS + 1, wsel3, p3, bit);
      mix_update(&s->mf, min4, 4, wself, pr12, bit);
      apm_update(s, &s->apm1, &ap1, bit);
      apm_update(s, &s->apm2, &ap2, bit);
      node = node * 2 + bit;
      sub = sub * 2 + bit;
    }
    px[i] = (uint8_t)(node - (1 << bits));
    if (PV != NONE) {
      if (px[i] == transp) cntT++;
      if (px[i] == PV) cntV++;
    }
  }
#undef P
  r->run = run; r->cntT = cntT; r->cntV = cntV;
  r->mLen = mLen; r->mPtr = mPtr;
}

/* The compiler that built the C part, for the command's --version and
   report: a string constant, no library */
const char *paia_c_compiler(void) {
#if defined(__clang__)
  return "clang " __clang_version__;
#elif defined(__GNUC__)
  return "gcc " __VERSION__;
#else
  return "unknown C compiler";
#endif
}
