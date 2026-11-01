{ The models: what predicts each bit before the arithmetic coder codes it.

  TByteModel codes plain bytes (the GIF's headers, palettes, extensions, and
  the side information of each image): orders 0 to 3, mixed.

  TPixelModel codes an image's palette indices, one bit at a time from the
  top, from their neighbours in the image (left, up, and around) and in the
  previous image of the same width, the frame before in an animation.
  Most pixels of a GIF repeat one of these: so each pixel first codes one
  flag, "it is the candidate" (the previous frame's pixel, or the left one),
  and only when it is not, its bits.

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

uses SysUtils, paiaarith;

const
  PIXEL_CONTEXTS = 9;
  FLAG_CONTEXTS = 6;

type
  TWords = array of Word;

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
    mx: TMixer;
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
      transp: this image's transparent index, or -1. }
    procedure CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                        const cv, pw: TWords; transp: Integer);
    { the reference: what paiapix.c does, in Pascal }
    procedure CodeImagePascal(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                              const cv, pw: TWords; transp: Integer);
  end;

{ True when the C model is linked in (the release build); the checked build
  is Pascal only, and the tests compare the two. }
function UsingC: Boolean;

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
  TCMixer = record w: PLongInt; nIn, rate: LongInt; end;
  TCApm = record t: PLongInt; rate, pad: LongInt; end;
  TPixState = record
    t: array[0..PIXEL_CONTEXTS - 1] of TCCounters;
    ft: array[0..FLAG_CONTEXTS - 1] of TCCounters;
    mx, fmx: TCMixer;
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
  TCRun = record run, cntT, cntV, pad: LongInt; end;

procedure paia_code_pixels(s: Pointer; cd: Pointer; px: PByte; i0, i1, n, width: Int64;
                           bits: LongInt; cv, pw: PWord; transp: LongInt; r: Pointer);
  cdecl; external name 'paia_code_pixels';
{$endif}

function UsingC: Boolean;
begin
  {$ifdef PAIA_C} Result := True; {$else} Result := False; {$endif}
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
  mx.Init(6, 2 * 256 * 2, 6);
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
  for i := 0 to High(t) do t[i].Init(tableBits, 255);
  mx.Init(Length(t) + 1, 8 * 8, 4);
  apm1.Init(256 * 256, 7);
  apm2.Init(256 * 256, 7);
  for i := 0 to High(ft) do ft[i].Init(tableBits - 2, 255);
  fmx.Init(FLAG_CONTEXTS + 1, 16 * 4, 4);
  fapm.Init(1024 * 16, 7);
end;

procedure TPixelModel.CodeImage(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                                const cv, pw: TWords; transp: Integer);
{$ifdef PAIA_C}
const BATCH = 65536;
var st: TPixState; cs: TCState; j: Integer; i0, i1, need: Int64; r: TCRun; pcv, ppw: PWord;
  procedure C(var c: TCCounters; const t: TCounters);
  begin c.e := @t.e[0]; c.mask := t.mask; c.limit := t.limit; c.pad := 0; end;
begin
  if width < 1 then width := 1;
  if n <= 0 then Exit;
  st := Default(TPixState);
  for j := 0 to High(t) do C(st.t[j], t[j]);
  for j := 0 to High(ft) do C(st.ft[j], ft[j]);
  st.mx.w := @mx.w[0]; st.mx.nIn := mx.nIn; st.mx.rate := mx.rate;
  st.fmx.w := @fmx.w[0]; st.fmx.nIn := fmx.nIn; st.fmx.rate := fmx.rate;
  st.apm1.t := @apm1.t[0]; st.apm1.rate := apm1.rate;
  st.apm2.t := @apm2.t[0]; st.apm2.rate := apm2.rate;
  st.fapm.t := @fapm.t[0]; st.fapm.rate := fapm.rate;
  st.stretchTab := @stretchTab[0]; st.squashTab := @squashTab[0];
  st.apmBase := @apmBase[0]; st.rateTab := @rateTab[0];
  r.run := 0; r.cntT := Ord(transp >= 0); r.cntV := 0; r.pad := 0;
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
    paia_code_pixels(@st, @cs, @px[0], i0, i1, n, width, bits, pcv, ppw, transp, @r);
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
  CodeImagePascal(cd, px, n, width, bits, cv, pw, transp);
end;
{$endif}

procedure TPixelModel.CodeImagePascal(cd: TCoder; var px: TBytes; n: SizeInt; width, bits: Integer;
                                      const cv, pw: TWords; transp: Integer);
const NONE = 256;
var i: SizeInt; x, y, L, U, UL, UR, LL, UU, PV, PR, PD, PW_, v, node, sub, bit, b, j, pm, pa,
    pr12, sel, cand, pat, run, cntT, cntV: Integer; fidx: array[0..FLAG_CONTEXTS - 1] of SizeInt;
    base: array[0..PIXEL_CONTEXTS - 1] of QWord;
    slot: array[0..PIXEL_CONTEXTS - 1] of SizeInt;
    w: SizeInt;
begin
  if width < 1 then width := 1;
  w := width;
  x := 0; y := 0; run := 0;
  cntT := Ord(transp >= 0); cntV := 0;
  FillChar(slot, SizeOf(slot), 0);
  for i := 0 to n - 1 do begin
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
    base[0] := QWord(bits) * 512 + QWord(cand);
    base[1] := Hash(L, 1);
    base[2] := Hash(U, 2);
    base[3] := Hash(L * 512 + U, 3);
    base[4] := Hash(Hash(L * 512 + U, UL * 512 + UR), 4);
    base[5] := Hash(Hash(L * 512 + LL, U * 512 + UU), 5);
    base[6] := Hash(Hash(PV, L * 512 + U), 6);
    base[7] := Hash(Hash(PV * 512 + PR, PD), 7 + PW_ * 16);
    base[8] := Hash(Hash(UL * 512 + U, UR), 8);
    sel := Ord(L = U) + 2 * Ord((PV <> NONE) and (PV = L)) + 4 * Ord(U = UR);
    node := 1; sub := 1;
    for b := bits - 1 downto 0 do begin
      { a new slot for the top group (bits above the low four) and the low four }
      if (b = bits - 1) or (b = 3) then begin
        for j := 0 to High(t) do
          slot[j] := (Hash(base[j], node) shl 4) and t[j].mask;
        sub := 1;
      end;
      for j := 0 to High(t) do mx.Add(Stretch(t[j].P12(slot[j] + sub)));
      mx.Add(256);
      pm := mx.Mix((bits - 1 - b) * 8 + sel);
      pa := apm1.Refine(pm, ((L and 255) shl 8) or (node and 255));
      pr12 := apm2.Refine(pm, ((U and 255) shl 8) or (node and 255));
      pr12 := (2 * pm + pa + pr12) div 4;
      bit := cd.Code((v shr b) and 1, pr12);
      for j := 0 to High(t) do t[j].Update(slot[j] + sub, bit);
      mx.Update(bit);
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
