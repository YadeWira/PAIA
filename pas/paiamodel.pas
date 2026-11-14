{ The models: what predicts each bit before the arithmetic coder codes it.

  TByteModel codes plain bytes (the GIF's headers, palettes, extensions, and
  the side information of each image): orders 0 to 3, mixed.

  TPixelModel codes an image's palette indices, one bit at a time from the
  top, from their neighbours in the image (left, up, and around) and in the
  previous image of the same width, the frame before in an animation.
  Most pixels of a GIF repeat one of these: so each pixel first codes one
  flag, "it is the candidate" (the previous frame's pixel, or the left one),
  and only when it is not, its bits. Those bits see 36 contexts: pairs and
  triples of neighbours up to four pixels away (as paq8px's 8-bit image
  model), the column, what followed the last six pixels where they were
  seen before (a match), and the pixels one period back across and down
  when the image repeats itself (a tiled background). Three mixers, chosen
  by the bit, the bits so far and the left pixel, and a fourth that mixes
  them.

  The counters of one context are kept in slots of 16 (64 bytes, a cache
  line): one slot for the high bits of a symbol, one for the low four,
  chosen by the high ones (as lpaq does). So a context costs two cache
  misses a symbol instead of one a bit.

  Both are written so that the encoder and the decoder run the very same
  code: TCoder.Code returns the bit, given on one side, decoded on the
  other. Integer only. }
unit paiamodel;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiamodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiamodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, Math, paiaarith;

const
  PIXEL_CONTEXTS = 36;
  FLAG_CONTEXTS = 7;
  { the match: the last MATCH_MIN pixels find where they were before }
  MATCH_MIN = 6;

type
  TWords = array of Word;
  TLongInts = array of LongInt;

  TByteModel = class
  private
    t0: TCounters;                  { order 0, direct }
    t: array[1..3] of TCounters;    { orders 1 to 3, in slots }
    mx: TMixer;
    apm: TApm;
    mm: array[0..1] of TMatchModel;    { per stream }
    c1, c2, c3: array[0..1] of Byte;   { per stream: S_RAW, S_AUX }
  public
    { tableBits: log2 of the counters of each order-1..3 table }
    constructor Create(tableBits: Integer);
    function Code(cd: TCoder; b: Integer; stream: Integer): Integer;
    { 7 bits a byte, the high bit set on all but the last }
    function CodeVarint(cd: TCoder; v: QWord; stream: Integer): QWord;
  end;

  TPixelModel = class
  private
    t: array[0..PIXEL_CONTEXTS - 1] of TCounters;
    mx, mx2, mx3, mf: TMixer;
    apm1, apm2: TApm;
    { the "same as the candidate" flag }
    ft: array[0..FLAG_CONTEXTS - 1] of TCounters;
    fmx: TMixer;
    fapm: TApm;
  public
    constructor Create(tableBits: Integer);
    { Codes px[0..n) (decoding: fills it), an image `width` wide, with
      `bits` bits a pixel. cv: for each pixel, the canvas under it before
      this image (256: none); pw: the previous image's pixel at the same
      place (256: none, 257: it was transparent there); either may be nil.
      transp: this image's transparent index, or -1. perX, perY: the
      distances at which it repeats across and down (FindPeriods), or 0. }
    procedure CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                        const cv, pw: TWords; transp, perX, perY: Integer);
    { the reference: what paiapix.c does, in Pascal }
    procedure CodeImagePascal(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                              const cv, pw: TWords; transp, perX, perY: Integer;
                              var mt: TLongInts);
  end;

{ True when the C model is linked in (the release build); the checked build
  is Pascal only, and the tests compare the two. }
function UsingC: Boolean;
{ the C compiler that built the C model, as it names itself ('' without C) }
function CCompilerName: string;

var
  { the C model where it is linked in, or the Pascal one (--cpu=pascal):
    the same bytes. Set before any work starts. }
  UseCModel: Boolean = True;

{ The encoder's choice: across (perX) and down (perY), the distance from 8
  to 512 at which most pixels repeat, sampled on some rows; 0 for an image
  under 4096 pixels or too narrow (short). Only a guess: any value codes. }
procedure FindPeriods(const px: TBytes; n: SizeInt; width: Integer; out perX, perY: Integer);

{ The table size for a model that will see about `symbols` symbols:
  enough slots for two per symbol, between 2^12 and 2^22 counters. }
function TableBitsFor(symbols: QWord): Integer;

implementation

{$if defined(PAIA_FAST) and not defined(PAIA_PURE)}
  {$define PAIA_C}
{$endif}

{$ifdef PAIA_C}
{$L paiapix.o}
{$packrecords C}
type
  TCCounters = record e: PLongWord; mask: Int64; limit, pad: LongInt; end;
  TCMixer = record w: PLongInt; nIn, rate, shift, pad: LongInt; end;
  TCApm = record t: PLongInt; rate, pad: LongInt; end;
  TPixState = record
    t: array[0..PIXEL_CONTEXTS - 1] of TCCounters;
    ft: array[0..FLAG_CONTEXTS - 1] of TCCounters;
    mx, mx2, mx3, mf, fmx: TCMixer;
    apm1, apm2, fapm: TCApm;
    stretchTab, squashTab: PSmallInt;
    apmBase, rateTab: PLongInt;
  end;
  TCState = record
    encoding: LongInt;
    x1, x2, x: LongWord;
    buf: PByte;
    n, p, last: Int64;
  end;
{$packrecords default}

type
  { what has to survive from one batch to the next }
  TCRun = record
    run, cntT, cntV, mLen, mPtr, mMask, perX, perY: LongInt;
    mt: PLongInt;
  end;

{ external with no name: FreePascal gives it the platform's C name (a
  leading underscore on 32-bit Windows and on macOS) }
procedure paia_code_pixels(s: Pointer; cd: Pointer; px: PByte; i0, i1, n, width: Int64;
                           bits: LongInt; cv, pw: PWord; transp: LongInt; r: Pointer;
                           x0, y0: Int64);
  cdecl; external;
function paia_c_compiler: PChar; cdecl; external;
{$endif}

function UsingC: Boolean;
begin
  {$ifdef PAIA_C} Result := True; {$else} Result := False; {$endif}
end;

function CCompilerName: string;
begin
  {$ifdef PAIA_C} Result := StrPas(paia_c_compiler); {$else} Result := ''; {$endif}
end;

{ 32-bit mixing of a value, without overflow traps }
function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

function TableBitsFor(symbols: QWord): Integer;
begin
  Result := 12;
  while (Result < 22) and ((QWord(1) shl (Result - 5)) < symbols) do Inc(Result);
end;

{ ---------------- bytes ---------------- }

constructor TByteModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  t0.Init(10, 60);
  for i := 1 to 3 do t[i].Init(tableBits, 60);
  mx.Init(6, 2 * 256 * 2, 2);
  mm[0].Init(tableBits - 2);
  mm[1].Init(16);
  apm.Init(2 * 256 * 256, 7);       { streams 0 and 1 }
  FillChar(c1, SizeOf(c1), 0); FillChar(c2, SizeOf(c2), 0); FillChar(c3, SizeOf(c3), 0);
end;

function TByteModel.Code(cd: TCoder; b: Integer; stream: Integer): Integer;
var node, sub, bit, i, j, p, pm, pa, e: Integer; base: array[1..3] of QWord;
    slot: array[1..3] of SizeInt; i0: SizeInt;
begin
  base[1] := Hash(QWord(stream) * 256 + c1[stream], 1);
  base[2] := Hash(QWord(stream) * 65536 + QWord(c1[stream]) * 256 + c2[stream], 2);
  base[3] := Hash(Hash(QWord(c1[stream]) * 65536 + QWord(c2[stream]) * 256 + c3[stream], 3), stream);
  slot[1] := 0; slot[2] := 0; slot[3] := 0;
  e := mm[stream].Expected(0);
  node := 1; sub := 1;
  for i := 7 downto 0 do begin
    if (i = 7) or (i = 3) then begin
      for j := 1 to 3 do
        slot[j] := (Hash(base[j], node) shl 4) and t[j].mask;
      sub := 1;
    end;
    i0 := (stream * 256 + node) and t0.mask;
    mx.Add(Stretch(t0.P12(i0)));
    for j := 1 to 3 do mx.Add(Stretch(t[j].P12(slot[j] + sub)));
    mx.Add(mm[stream].Input(e, 8, node, i));
    mx.Add(256);
    pm := mx.Mix((stream * 256 + node) * 2 + Ord(mm[stream].len >= 16));
    pa := apm.Refine(pm, (SizeInt(stream) * 256 + c1[stream]) * 256 + node);
    p := (pm + 3 * pa) div 4;
    bit := cd.Code((b shr i) and 1, p);
    t0.Update(i0, bit);
    for j := 1 to 3 do t[j].Update(slot[j] + sub, bit);
    mx.Update(bit);
    apm.Update(bit);
    mm[stream].Learn(bit);
    node := node * 2 + bit;
    sub := sub * 2 + bit;
  end;
  Result := node and 255;
  mm[stream].Update(Result);
  c3[stream] := c2[stream]; c2[stream] := c1[stream]; c1[stream] := Result;
end;

function TByteModel.CodeVarint(cd: TCoder; v: QWord; stream: Integer): QWord;
var b, shift: Integer;
begin
  Result := 0; shift := 0;
  repeat
    if cd.encoding then begin
      b := v and 127; v := v shr 7;
      if v <> 0 then b := b or 128;
    end else b := 0;
    b := Code(cd, b, stream);
    if shift > 63 then raise Exception.Create('paiamodel: varint too long');
    Result := Result or (QWord(b and 127) shl shift);
    shift := shift + 7;
  until (b and 128) = 0;
end;

{ ---------------- pixels ---------------- }

constructor TPixelModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  { the first nine (the nearest neighbours) get the full size, the others a
    quarter: 0.2% bigger, 244 MB instead of 544 for a large image }
  for i := 0 to High(t) do
    if i < 9 then t[i].Init(tableBits, 30) else t[i].Init(Max(12, tableBits - 2), 30);
  mx.Init(Length(t) + 1, 8 * 8, 1, 13);
  mx2.Init(Length(t) + 1, 256, 1, 13);
  mx3.Init(Length(t) + 1, 257 * 8, 1, 13);
  mf.Init(4, 8 * 7, 1, 13);
  apm1.Init(256 * 256, 6);
  apm2.Init(256 * 256, 6);
  for i := 0 to High(ft) do ft[i].Init(tableBits - 2, 30);
  fmx.Init(FLAG_CONTEXTS + 1, 16 * 4, 1, 11);
  fapm.Init(1024 * 16, 6);
end;

procedure FindPeriods(const px: TBytes; n: SizeInt; width: Integer; out perX, perY: Integer);
var rows, step, d, y, x, best, cnt: Integer;
begin
  perX := 0; perY := 0;
  if (width < 1) or (n < 4096) then Exit;
  rows := n div width;
  { about 64 rows, every 7th at most }
  step := Max(7, rows div 64);
  best := 0;
  for d := 8 to Min(width div 2, 512) do begin
    cnt := 0; y := 0;
    while y < rows do begin
      for x := d to width - 1 do
        if px[SizeInt(y) * width + x] = px[SizeInt(y) * width + x - d] then Inc(cnt);
      Inc(y, step);
    end;
    if cnt > best then begin best := cnt; perX := d; end;
  end;
  best := 0;
  for d := 8 to Min(rows div 2, 512) do begin
    cnt := 0; y := d;
    while y < rows do begin
      for x := 0 to width - 1 do
        if px[SizeInt(y) * width + x] = px[SizeInt(y - d) * width + x] then Inc(cnt);
      Inc(y, step);
    end;
    if cnt > best then begin best := cnt; perY := d; end;
  end;
end;

{ the match's table: a power of two, about the pixels, 2^10 to 2^22 }
function MatchMask(n: SizeInt): LongInt;
begin
  Result := 1023;
  while (Result < n) and (Result < (1 shl 22) - 1) do Result := Result * 2 + 1;
end;

procedure TPixelModel.CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                                const cv, pw: TWords; transp, perX, perY: Integer);
var mt: TLongInts;
{$ifdef PAIA_C}
const BATCH = 65536;
var st: TPixState; cs: TCState; j: Integer; i0, i1, need: Int64; r: TCRun; pcv, ppw: PWord;
  procedure C(var c: TCCounters; const t: TCounters);
  begin c.e := @t.e[0]; c.mask := t.mask; c.limit := t.limit; c.pad := 0; end;
  procedure M(var c: TCMixer; const m: TMixer);
  begin c.w := @m.w[0]; c.nIn := m.nIn; c.rate := m.rate; c.shift := m.shift; c.pad := 0; end;
begin
  mt := nil;
  if not UseCModel then begin
    CodeImagePascal(cd, px, n, width, bits, cv, pw, transp, perX, perY, mt);
    Exit;
  end;
  if width < 1 then width := 1;
  if n <= 0 then Exit;
  st := Default(TPixState);
  for j := 0 to High(t) do C(st.t[j], t[j]);
  for j := 0 to High(ft) do C(st.ft[j], ft[j]);
  M(st.mx, mx); M(st.mx2, mx2); M(st.mx3, mx3); M(st.mf, mf); M(st.fmx, fmx);
  st.apm1.t := @apm1.t[0]; st.apm1.rate := apm1.rate;
  st.apm2.t := @apm2.t[0]; st.apm2.rate := apm2.rate;
  st.fapm.t := @fapm.t[0]; st.fapm.rate := fapm.rate;
  st.stretchTab := @stretchTab[0]; st.squashTab := @squashTab[0];
  st.apmBase := @apmBase[0]; st.rateTab := @rateTab[0];
  r := Default(TCRun);
  r.cntT := Ord(transp >= 0);
  r.mMask := MatchMask(n);
  SetLength(mt, r.mMask + 1);
  r.mt := @mt[0];
  r.perX := perX; r.perY := perY;
  if cv <> nil then pcv := @cv[0] else pcv := nil;
  if pw <> nil then ppw := @pw[0] else ppw := nil;
  i0 := 0;
  while i0 < n do begin
    i1 := i0 + BATCH; if i1 > n then i1 := n;
    cs := Default(TCState);
    cs.encoding := Ord(cd.encoding);
    if cd.encoding then begin
      { at most 12 bits out per bit coded: (bits + 1) coded bits a pixel }
      need := cd.enc.n + (i1 - i0) * (bits + 1) * 2 + 64;
      if Length(cd.enc.d) < need then SetLength(cd.enc.d, need + need div 2);
      cs.x1 := cd.enc.x1; cs.x2 := cd.enc.x2;
      cs.buf := @cd.enc.d[0]; cs.n := cd.enc.n;
    end else begin
      cs.x1 := cd.dec.x1; cs.x2 := cd.dec.x2; cs.x := cd.dec.x;
      cs.buf := @cd.dec.d[0]; cs.p := cd.dec.p; cs.last := cd.dec.last;
    end;
    paia_code_pixels(@st, @cs, @px[0], i0, i1, n, width, bits, pcv, ppw, transp, @r,
                     i0 mod width, i0 div width);
    if cd.encoding then begin
      cd.enc.x1 := cs.x1; cd.enc.x2 := cs.x2; cd.enc.n := cs.n;
    end else begin
      cd.dec.x1 := cs.x1; cd.dec.x2 := cs.x2; cd.dec.x := cs.x; cd.dec.p := cs.p;
    end;
    i0 := i1;
  end;
end;
{$else}
begin
  mt := nil;
  CodeImagePascal(cd, px, n, width, bits, cv, pw, transp, perX, perY, mt);
end;
{$endif}

{ the pixel px[i] dx across and dy up, the image `width` wide and px[i] at
  x, y; 256 outside it }
function Far(const px: TBytes; i: SizeInt; x, y, width, dx, dy: Integer): Integer; inline;
begin
  if (x + dx < 0) or (x + dx >= width) or (y < dy) then Result := 256
  else Result := px[i + dx - SizeInt(dy) * width];
end;

procedure TPixelModel.CodeImagePascal(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                                      const cv, pw: TWords; transp, perX, perY: Integer;
                                      var mt: TLongInts);
const NONE = 256;
var i: SizeInt; x, y, L, U, UL, UR, LL, UU, PV, PR, PD, PW_, v, node, sub, bit, b, j, pm, pa,
    pr12, sel, cand, pat, run, cntT, cntV, bp, p2, p3: Integer; fidx: array[0..FLAG_CONTEXTS - 1] of SizeInt;
    NWW, NEE, NNWW, NNEE, NNW, NNE, WWW, NEEE, NEEEE, TX, TY, c0, c1: Integer;
    mMask, mPtr, mLen, MP, lb: Integer; mh: SizeInt;
    base: array[0..PIXEL_CONTEXTS - 1] of QWord;
    slot: array[0..PIXEL_CONTEXTS - 1] of SizeInt;
    w: SizeInt;
begin
  if width < 1 then width := 1;
  w := width;
  x := 0; y := 0; run := 0;
  cntT := Ord(transp >= 0); cntV := 0;
  FillChar(slot, SizeOf(slot), 0);
  mMask := MatchMask(n);
  mt := nil; SetLength(mt, mMask + 1);
  mPtr := 0; mLen := 0;
  for i := 0 to n - 1 do begin
    { the match: after the pixel before, still going, or found again from
      the last MATCH_MIN pixels (and how long it really is, up to 32) }
    if i > 0 then begin
      if mLen > 0 then begin
        if px[mPtr] = px[i - 1] then begin Inc(mLen); Inc(mPtr); end else mLen := 0;
      end;
      if i >= MATCH_MIN then begin
        mh := SizeInt(Hash(Hash(px[i - 1] * 256 + px[i - 2], px[i - 3] * 256 + px[i - 4]),
                           px[i - 5] * 256 + px[i - 6]) and QWord(mMask));
        if (mLen = 0) and (mt[mh] > 0) then begin
          mPtr := mt[mh];
          while (mLen < 32) and (mPtr - mLen - 1 >= 0) and (px[mPtr - mLen - 1] = px[i - mLen - 1]) do
            Inc(mLen);
          if mLen < MATCH_MIN then mLen := 0;
        end;
        mt[mh] := i;
      end;
    end;
    if mLen > 0 then MP := px[mPtr] else MP := NONE;
    if mLen = 0 then lb := 0 else if mLen < 8 then lb := 1 else if mLen < 12 then lb := 2
    else if mLen < 16 then lb := 3 else if mLen < 24 then lb := 4 else if mLen < 32 then lb := 5
    else lb := 6;

    if x > 0 then L := px[i - 1] else L := NONE;
    if x > 1 then LL := px[i - 2] else LL := NONE;
    if y > 0 then begin
      U := px[i - w];
      if x > 0 then UL := px[i - w - 1] else UL := NONE;
      if x + 1 < width then UR := px[i - w + 1] else UR := NONE;
    end else begin U := NONE; UL := NONE; UR := NONE; end;
    if y > 1 then UU := px[i - 2 * w] else UU := NONE;
    if cv <> nil then begin
      PV := cv[i];
      if (x + 1 < width) and (i + 1 < n) then PR := cv[i + 1] else PR := NONE;
      if i + w < n then PD := cv[i + w] else PD := NONE;
    end else begin PV := NONE; PR := NONE; PD := NONE; end;
    if pw <> nil then PW_ := pw[i] else PW_ := NONE;
    { the candidate: the canvas, or the transparent index if this image has
      used it more than the canvas's value so far }
    if PV <> NONE then begin
      if (transp >= 0) and (cntT >= cntV) then cand := transp else cand := PV;
    end
    else if L <> NONE then cand := L
    else if U <> NONE then cand := U
    else cand := 0;

    v := 0; if cd.encoding then v := px[i];

    { the flag: is it the candidate? }
    pat := Ord(cand = L) + 2 * Ord(cand = U) + 4 * Ord(cand = UL) + 8 * Ord(cand = UR)
         + 16 * Ord(cand = PR) + 32 * Ord(cand = PD) + 64 * Ord(L = U) + 128 * Ord(PV <> NONE)
         + 256 * Ord(cand = LL) + 512 * Ord(cand = UU)
         + 1024 * Ord(PW_ = 257) + 2048 * Ord((transp >= 0) and (cand = transp));
    fidx[0] := pat and ft[0].mask;
    fidx[1] := Hash(pat, run) and ft[1].mask;
    fidx[2] := Hash(Hash(L * 512 + U, cand), 11) and ft[2].mask;
    fidx[3] := Hash(Hash(PV * 512 + PR, PD * 512 + L), 12 + PW_ * 16) and ft[3].mask;
    fidx[4] := Hash(Hash(L * 512 + U, UL * 512 + UR), cand + 13 * 512) and ft[4].mask;
    fidx[5] := Hash(Hash(UU * 512 + LL, cand), pat + 14 * 2048) and ft[5].mask;
    fidx[6] := Hash(Hash(Ord(MP = cand) + 2 * Ord(MP = NONE), lb), (pat and 63) + 15 * 2048) and ft[6].mask;
    for j := 0 to High(ft) do fmx.Add(Stretch(ft[j].P12(fidx[j])));
    fmx.Add(256);
    pm := fmx.Mix(run * 4 + (pat and 3));
    pa := fapm.Refine(pm, (pat and 1023) * 16 + run);
    pr12 := (pm + 3 * pa) div 4;
    bit := cd.Code(Ord(v = cand), pr12);
    for j := 0 to High(ft) do ft[j].Update(fidx[j], bit);
    fmx.Update(bit);
    fapm.Update(bit);
    if bit <> 0 then begin
      if run < 15 then Inc(run);
      px[i] := cand;
      if PV <> NONE then begin
        if cand = transp then Inc(cntT);
        if cand = PV then Inc(cntV);
      end;
      Inc(x);
      if x = width then begin x := 0; Inc(y); end;
      Continue;
    end;
    run := 0;

    { the pixel's bits are predicted from what is seen: a transparent
      neighbour shows the canvas under it }
    if (transp >= 0) and (cv <> nil) then begin
      if (L = transp) and (cv[i - 1] <> NONE) then L := cv[i - 1];
      if (LL = transp) and (cv[i - 2] <> NONE) then LL := cv[i - 2];
      if (U = transp) and (cv[i - w] <> NONE) then U := cv[i - w];
      if (UL = transp) and (cv[i - w - 1] <> NONE) then UL := cv[i - w - 1];
      if (UR = transp) and (cv[i - w + 1] <> NONE) then UR := cv[i - w + 1];
      if (UU = transp) and (cv[i - 2 * w] <> NONE) then UU := cv[i - 2 * w];
    end;
    { farther ones, as they are }
    NWW := Far(px, i, x, y, width, -2, 1); NEE := Far(px, i, x, y, width, 2, 1);
    NNWW := Far(px, i, x, y, width, -2, 2); NNEE := Far(px, i, x, y, width, 2, 2);
    NNW := Far(px, i, x, y, width, -1, 2); NNE := Far(px, i, x, y, width, 1, 2);
    WWW := Far(px, i, x, y, width, -3, 0); NEEE := Far(px, i, x, y, width, 3, 1);
    NEEEE := Far(px, i, x, y, width, 4, 1);
    if perX > 0 then TX := Far(px, i, x, y, width, -perX, 0) else TX := NONE;
    if perY > 0 then TY := Far(px, i, x, y, width, 0, perY) else TY := NONE;
    c0 := x * 16 div width; c1 := x * 64 div width;
    base[0] := QWord(bits) * 512 + QWord(cand);
    base[1] := Hash(L, 1);
    base[2] := Hash(U, 2);
    base[3] := Hash(L * 512 + U, 3);
    base[4] := Hash(Hash(L * 512 + U, UL * 512 + UR), 4);
    base[5] := Hash(Hash(L * 512 + LL, U * 512 + UU), 5);
    base[6] := Hash(Hash(PV, L * 512 + U), 6);
    base[7] := Hash(Hash(PV * 512 + PR, PD), 7 + PW_ * 16);
    base[8] := Hash(Hash(UL * 512 + U, UR), 8);
    base[9] := Hash(Hash(L, c0), 9);
    base[10] := Hash(Hash(U, c0), 10);
    base[11] := Hash(Hash(UL, c0), 11);
    base[12] := Hash(Hash(UR, c0), 12);
    base[13] := Hash(NWW, 13);
    base[14] := Hash(NEE, 14);
    base[15] := Hash(LL, 15);
    base[16] := Hash(UU, 16);
    base[17] := Hash(Hash(L, UR), 17);
    base[18] := Hash(Hash(U, UU), 18);
    base[19] := Hash(Hash(UL, NNWW), 19);
    base[20] := Hash(Hash(UR, NNEE), 20);
    base[21] := Hash(Hash(L, WWW), 21);
    base[22] := Hash(Hash(LL, NEE), 22);
    base[23] := Hash(Hash(L, NEEE), 23);
    base[24] := Hash(Hash(L, NEEEE), 24);
    base[25] := Hash(Hash(L * 512 + UR, NEE), 25);
    base[26] := Hash(Hash(U * 512 + UR, UU * 512 + NNE), 26);
    base[27] := Hash(Hash(U * 512 + UL, NNW * 512 + UU), 27);
    base[28] := Hash(Hash(L * 512 + LL, NWW * 512 + UL), 28);
    base[29] := Hash(c0, 29);
    base[30] := Hash(Hash(U, c1), 30);
    base[31] := Hash(Hash(L, c1), 31);
    base[32] := Hash(Hash(MP, lb), 32);
    base[33] := Hash(Hash(MP * 512 + L, lb), 33);
    base[34] := Hash(Hash(TX, TY), 34);
    base[35] := Hash(Hash(TX * 512 + TY, L * 512 + U), 35);
    sel := Ord(L = U) + 2 * Ord((PV <> NONE) and (PV = L)) + 4 * Ord(U = UR);
    node := 1; sub := 1;
    for b := bits - 1 downto 0 do begin
      bp := bits - 1 - b;
      { a new slot for the top group (bits above the low four) and the low four }
      if (b = bits - 1) or (b = 3) then begin
        for j := 0 to High(t) do
          slot[j] := (Hash(base[j], node) shl 4) and t[j].mask;
        sub := 1;
      end;
      for j := 0 to High(t) do begin
        pa := Stretch(t[j].P12(slot[j] + sub));
        mx.Add(pa); mx2.Add(pa); mx3.Add(pa);
      end;
      mx.Add(256); mx2.Add(256); mx3.Add(256);
      pm := mx.Mix(bp * 8 + sel);
      p2 := mx2.Mix(node and 255);
      p3 := mx3.Mix(L * 8 + bp);
      mf.Add(Stretch(pm)); mf.Add(Stretch(p2)); mf.Add(Stretch(p3)); mf.Add(256);
      pm := mf.Mix(bp * 7 + lb);
      pa := apm1.Refine(pm, ((L and 255) shl 8) or (node and 255));
      pr12 := apm2.Refine(pm, ((U and 255) shl 8) or (node and 255));
      pr12 := (pm + pa + 2 * pr12) div 4;
      bit := cd.Code((v shr b) and 1, pr12);
      for j := 0 to High(t) do t[j].Update(slot[j] + sub, bit);
      mx.Update(bit); mx2.Update(bit); mx3.Update(bit); mf.Update(bit);
      apm1.Update(bit);
      apm2.Update(bit);
      node := node * 2 + bit;
      sub := sub * 2 + bit;
    end;
    px[i] := node - (1 shl bits);
    if PV <> NONE then begin
      if px[i] = transp then Inc(cntT);
      if px[i] = PV then Inc(cntV);
    end;
    Inc(x);
    if x = width then begin x := 0; Inc(y); end;
  end;
end;

end.
