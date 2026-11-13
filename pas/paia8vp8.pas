{ FROZEN: the decoder of codec stream version 8, as PAIA 0.1.0 and 0.2.0 wrote it
  (a copy of paiavp8.pas at v0.2.0 = 60b2031, units renamed paia8*). Version 8
  is read forever, bit for bit (doc/STABILITY.md): never change this file;
  the live codec (paiavp8.pas) writes version 9 and up. }
{ WebP lossy frames: VP8 key frames, recoded at the level of the boolean
  coder's decisions.

  A VP8 frame is a header and partitions, each a boolean-coded (binary
  arithmetic) stream: the first holds the frame header, the probabilities
  and each macroblock's modes, the others the DCT coefficients' tokens. A
  boolean decoder with the right sequence of probabilities, and an encoder
  given the same decisions with the same probabilities, are exact inverses:
  so each decision is read with its probability, coded with a model of its
  own (which also sees that probability), and on extraction written again
  with libwebp's own boolean writer. The bytes come back equal up to where
  each partition is closed; whatever a writer put there that ours would
  not (a different flush, bytes past the end) is kept as it is.

  The model of a coefficient decision sees what VP8's does not: the
  coefficients at the same place in the blocks above and to the left
  (Lepton's and packJPG's main idea), how many are non-zero so far in the
  block, the last one's size, its place. None of this, nor the tables,
  can break exactness: a wrong context only picks another probability to
  decode with, and the same one to encode with.

  Tables and parsing follow libwebp 1.5.0 (see NOTICE). One walk checks,
  encodes and decodes. }
unit paia8vp8;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paia8vp8: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paia8vp8: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paia8arith;

type
  TVp8Stream = record
    dataStart, dataEnd: SizeInt;
  end;
  TVp8Streams = array of TVp8Stream;

  TVp8Model = class
  private
    t: array[0..4] of TCounters;
    mx: TMixer;
    apm, apm2: TApm;
  public
    constructor Create(tableBits: Integer);
    function CodeBit(cd: TCoder; bit, prob: Integer; h1, h2, h3: QWord; sel: Integer;
                     h4: QWord = 0; h5: QWord = 0): Integer;
  end;

function FindVp8Streams(const d: TBytes): TVp8Streams;

procedure CodeVp8Stream(cd: TCoder; m: TVp8Model; var data: TBytes; len: SizeInt);

implementation

{$I paia8vp8tables.inc}

const
  BANDS: array[0..16] of Integer = (0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0);
  ZIGZAG: array[0..15] of Integer = (0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15);
  CAT3: array[0..2] of Integer = (173, 148, 140);
  CAT4: array[0..3] of Integer = (176, 155, 140, 135);
  CAT5: array[0..4] of Integer = (180, 157, 141, 134, 130);
  CAT6: array[0..10] of Integer = (254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129);
  MAX_MBS = 65536;

  MODE_CHECK = 0; MODE_ENC = 1; MODE_DEC = 2;

function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

{ ---------------- the model ---------------- }

constructor TVp8Model.Create(tableBits: Integer);
var i, s: Integer;
begin
  inherited Create;
  for i := 0 to High(t) do t[i].Init(tableBits, 255);
  mx.Init(Length(t) + 2, 256, 1);
  { at first, VP8's own probability alone }
  for s := 0 to 255 do
    for i := 0 to mx.nIn - 1 do
      if i = 0 then mx.w[s * mx.nIn + i] := 65536 else mx.w[s * mx.nIn + i] := 0;
  apm.Init(256 * 4, 6);
  apm2.Init(256, 6);
end;

function TVp8Model.CodeBit(cd: TCoder; bit, prob: Integer; h1, h2, h3: QWord; sel: Integer;
                           h4: QWord; h5: QWord): Integer;
var p0, pm, pa, pb, j: Integer; idx: array[0..4] of SizeInt;
begin
  { VP8's probability is of a zero }
  p0 := (256 - prob) * 16;
  if p0 < 1 then p0 := 1 else if p0 > 4095 then p0 := 4095;
  mx.Add(Stretch(p0));
  idx[0] := h1 and t[0].mask; idx[1] := h2 and t[1].mask; idx[2] := h3 and t[2].mask;
  idx[3] := h4 and t[3].mask; idx[4] := h5 and t[4].mask;
  for j := 0 to 4 do mx.Add(Stretch(t[j].P12(idx[j])));
  mx.Add(256);
  pm := mx.Mix(sel and 255);
  pa := apm.Refine(pm, prob * 4 + ((sel shr 2) and 3));
  pb := apm2.Refine(pm, sel and 255);
  Result := cd.Code(bit, (2 * pm + pa + pb) div 4);
  for j := 0 to 4 do t[j].Update(idx[j], Result);
  mx.Update(Result);
  apm.Update(Result);
  apm2.Update(Result);
end;

{ ---------------- boolean coder ---------------- }

type
  { RFC 6386's decoder }
  TBoolDec = record
    d: TBytes;
    pos, last: SizeInt;
    value, range: LongWord;
    count: Integer;
    procedure Init(const data: TBytes; first, len: SizeInt);
    function Get(prob: Integer): Integer;
  end;

  { libwebp's writer (VP8BitWriter), so that its streams come back whole }
  TBoolEnc = record
    buf: TBytes;
    n: SizeInt;
    range, value: LongInt;
    run, nbBits: Integer;
    procedure Init;
    procedure Flush;
    procedure Put(bit, prob: Integer);
    function Finish: TBytes;
  end;

procedure TBoolDec.Init(const data: TBytes; first, len: SizeInt);
var i: Integer;
begin
  d := data; pos := first; last := first + len;
  value := 0;
  for i := 0 to 1 do begin
    value := value shl 8;
    if pos < last then value := value or d[pos];
    Inc(pos);
  end;
  range := 255; count := 0;
end;

function TBoolDec.Get(prob: Integer): Integer;
var split, big: LongWord;
begin
  split := 1 + (((range - 1) * LongWord(prob)) shr 8);
  big := split shl 8;
  if value >= big then begin
    Result := 1; range := range - split; value := value - big;
  end else begin
    Result := 0; range := split;
  end;
  while range < 128 do begin
    value := value shl 1;
    range := range shl 1;
    Inc(count);
    if count = 8 then begin
      count := 0;
      if pos < last then value := value or d[pos];
      Inc(pos);
    end;
  end;
end;

procedure TBoolEnc.Init;
begin
  buf := nil; SetLength(buf, 1024); n := 0;
  range := 254; value := 0; run := 0; nbBits := -8;
end;

procedure TBoolEnc.Flush;
var s, bits, v, i: Integer;
begin
  s := 8 + nbBits;
  bits := value shr s;
  value := value - (bits shl s);
  nbBits := nbBits - 8;
  if (bits and $FF) <> $FF then begin
    if n + run + 1 > Length(buf) then SetLength(buf, (n + run + 1) * 2);
    if (bits and $100) <> 0 then
      if n > 0 then buf[n - 1] := (buf[n - 1] + 1) and 255;
    if run > 0 then begin
      if (bits and $100) <> 0 then v := 0 else v := $FF;
      for i := 1 to run do begin buf[n] := v; Inc(n); end;
      run := 0;
    end;
    buf[n] := bits and $FF; Inc(n);
  end else
    Inc(run);
end;

procedure TBoolEnc.Put(bit, prob: Integer);
var split, shift: Integer;
begin
  split := (range * prob) shr 8;
  if bit <> 0 then begin
    value := value + split + 1;
    range := range - (split + 1);
  end else
    range := split;
  if range < 127 then begin
    shift := 0;
    while range < 127 do begin range := range * 2 + 1; Inc(shift); end;
    value := value shl shift;
    nbBits := nbBits + shift;
    if nbBits > 0 then Flush;
  end;
end;

function TBoolEnc.Finish: TBytes;
var k: Integer;
begin
  { VP8PutBits(0, 9 - nbBits), then pad with zeroes and flush }
  for k := 1 to 9 - nbBits do Put(0, 128);
  nbBits := 0;
  Flush;
  Result := Copy(buf, 0, n);
end;

{ ---------------- the walk ---------------- }

type
  TPart = record
    dec: TBoolDec;
    enc: TBoolEnc;
    start, len: SizeInt;
  end;

  TWalk = record
    mode: Integer;
    cd: TCoder;
    m: TVp8Model;
    src: TBytes;                { encoding / checking: the stream }
    outp: TBytes;               { decoding: the stream being rebuilt }
    len: SizeInt;
    parts: array[0..8] of TPart;
    nparts: Integer;
    fail: Boolean;
    decisions: Int64;
    function BB(p, prob: Integer; h1, h2, h3: QWord; sel: Integer; h4: QWord = 0; h5: QWord = 0): Integer;
    function L(p, nbits, field: Integer): Integer;
    function RawByte(at: SizeInt; field: Integer): Integer;
  end;

function TWalk.BB(p, prob: Integer; h1, h2, h3: QWord; sel: Integer; h4: QWord; h5: QWord): Integer;
begin
  if fail then Exit(0);
  Inc(decisions);
  if decisions > Int64(1) shl 31 then begin fail := True; Exit(0); end;
  case mode of
    MODE_CHECK: Result := parts[p].dec.Get(prob);
    MODE_ENC: begin
      Result := parts[p].dec.Get(prob);
      parts[p].enc.Put(Result, prob);
      m.CodeBit(cd, Result, prob, h1, h2, h3, sel, h4, h5);
    end;
  else begin
    Result := m.CodeBit(cd, 0, prob, h1, h2, h3, sel, h4, h5);
    parts[p].enc.Put(Result, prob);
  end;
  end;
end;

function TWalk.L(p, nbits, field: Integer): Integer;
var i, b: Integer;
begin
  Result := 0;
  for i := nbits - 1 downto 0 do begin
    b := BB(p, 128, Hash(1000 + field, nbits * 32 + i), Hash(2000 + field, Result), 0, 63);
    Result := Result or (b shl i);
  end;
end;

{ a byte outside the boolean streams: coded bit by bit at one half }
function TWalk.RawByte(at: SizeInt; field: Integer): Integer;
var i, b, v: Integer;
begin
  if fail then Exit(0);
  if at >= len then begin fail := True; Exit(0); end;
  if mode = MODE_DEC then v := 0 else v := src[at];
  Result := 0;
  for i := 7 downto 0 do begin
    if mode = MODE_CHECK then b := (v shr i) and 1
    else b := m.CodeBit(cd, (v shr i) and 1, 128, Hash(3000 + field, i), Hash(3100 + field, Result), 0, 62);
    Result := Result or (b shl i);
  end;
  if mode = MODE_DEC then outp[at] := Result;
end;

type
  TFrame = record
    mbw, mbh: Integer;
    probas: array[0..3, 0..7, 0..2, 0..10] of Byte;
    useSkip: Boolean; skipP: Integer;
    updateMap: Boolean; segP: array[0..2] of Integer;
    { per macroblock column: what the row above left }
    topNz, topNzDc: array of Byte;
    topModes: array of Byte;           { 4 per column }
    topI4, topSkip: array of Byte;
    { coefficients, for the neighbours' contexts }
    cy, cu, cv, cy2: array of SmallInt;
    baseQ: Integer;
    segQ: array[0..3] of Integer; segAbs: Boolean; useSeg: Boolean;
    curQ: Integer;                     { the current macroblock's quantizer }
  end;

function Lim15(v: Integer): Integer; inline;
begin
  if v > 15 then Result := 15 else Result := v;
end;

function MagBucket(v: Integer): Integer; inline;
begin
  if v < 0 then v := -v;
  if v = 0 then Result := 0 else if v = 1 then Result := 1 else if v = 2 then Result := 2
  else if v <= 4 then Result := 3 else if v <= 8 then Result := 4 else if v <= 16 then Result := 5
  else Result := 6;
end;

{ One block's coefficients (libwebp's GetCoeffs); returns the position of
  the last non-zero coefficient plus one. coef: the block's 16 places in
  the frame's array; above, left: the neighbours' (-1: none). }
function GetCoeffs(var w: TWalk; var f: TFrame; p, t, ctx, first: Integer;
                   var arr: array of SmallInt; at, above, left: SizeInt): Integer;
var n, v, nzCount, prevMag, nb, sign, bit1, bit0, cat, k, z, node, nnz, qb, ma, ml: Integer;
    q: array[0..10] of Byte;
  function Neigh(pos: Integer): Integer;
  var a, l: Integer;
  begin
    if above >= 0 then a := Abs(arr[above + pos]) else a := 0;
    if left >= 0 then l := Abs(arr[left + pos]) else l := 0;
    Result := MagBucket(a + l);
  end;
  function Dc(prob, nodeId, pos: Integer): Integer;
  begin
    Result := w.BB(p, prob,
      Hash(t * 16 + pos, nodeId * 4 + ctx),
      Hash(100 + t * 16 + pos, nodeId * 16 + nb),
      Hash(200 + t * 64 + nodeId, nzCount * 16 + prevMag * 2 + Ord(pos > 4)),
      ((Lim15(nodeId) * 4 + t) * 4 + nzCount) and 255,
      Hash(300 + t * 16 + pos, nodeId * 256 + nnz * 16 + nzCount * 4 + qb),
      Hash(600 + t * 16 + pos, nodeId * 4096 + ma * 512 + ml * 64 + ctx * 16 + qb * 4 + Ord(nzCount > 0)));
  end;
  procedure Load(band, c: Integer);
  var i: Integer;
  begin
    for i := 0 to 10 do q[i] := f.probas[t, band, c, i];
  end;
begin
  FillChar(q, SizeOf(q), 0);
  nzCount := 0; prevMag := 0;
  { the neighbours' non-zero coefficients, and the quantizer, in buckets }
  nnz := 0;
  if above >= 0 then for k := 0 to 15 do if arr[above + k] <> 0 then Inc(nnz);
  if left >= 0 then for k := 0 to 15 do if arr[left + k] <> 0 then Inc(nnz);
  if nnz > 7 then nnz := 4 + (nnz - 8) div 8;
  if nnz > 7 then nnz := 7;
  qb := f.curQ shr 5;
  ma := 0; ml := 0;
  n := first;
  Load(BANDS[n], ctx);
  while n < 16 do begin
    nb := Neigh(ZIGZAG[n]);
    if above >= 0 then ma := MagBucket(arr[above + ZIGZAG[n]]) else ma := 7;
    if left >= 0 then ml := MagBucket(arr[left + ZIGZAG[n]]) else ml := 7;
    if Dc(q[0], 0, n) = 0 then Exit(n);           { end of block }
    while Dc(q[1], 1, n) = 0 do begin               { a zero }
      Inc(n);
      Load(BANDS[n], 0);
      if n = 16 then Exit(16);
      nb := Neigh(ZIGZAG[n]);
      if above >= 0 then ma := MagBucket(arr[above + ZIGZAG[n]]) else ma := 7;
      if left >= 0 then ml := MagBucket(arr[left + ZIGZAG[n]]) else ml := 7;
    end;
    { non-zero }
    if Dc(q[2], 2, n) = 0 then begin
      v := 1;
      node := 1;
    end else begin
      if Dc(q[3], 3, n) = 0 then begin
        if Dc(q[4], 4, n) = 0 then v := 2
        else v := 3 + Dc(q[5], 5, n);
      end else begin
        if Dc(q[6], 6, n) = 0 then begin
          if Dc(q[7], 7, n) = 0 then v := 5 + Dc(159, 11, n)
          else begin
            v := 7 + 2 * Dc(165, 12, n);
            v := v + Dc(145, 13, n);
          end;
        end else begin
          bit1 := Dc(q[8], 8, n);
          bit0 := Dc(q[9 + bit1], 9 + bit1, n);
          cat := 2 * bit1 + bit0;
          v := 0;
          case cat of
            0: for k := 0 to High(CAT3) do v := v + v + Dc(CAT3[k], 16 + k, n);
            1: for k := 0 to High(CAT4) do v := v + v + Dc(CAT4[k], 20 + k, n);
            2: for k := 0 to High(CAT5) do v := v + v + Dc(CAT5[k], 24 + k, n);
          else for k := 0 to High(CAT6) do v := v + v + Dc(CAT6[k], 30 + k, n);
          end;
          v := v + 3 + (8 shl cat);
        end;
      end;
      node := 2;
    end;
    { the sign: a half, with the neighbours' signs as context }
    z := ZIGZAG[n];
    k := 0;
    if (above >= 0) and (arr[above + z] <> 0) then k := k + 1 + Ord(arr[above + z] < 0);
    if (left >= 0) and (arr[left + z] <> 0) then k := k + 3 * (1 + Ord(arr[left + z] < 0));
    sign := w.BB(p, 128, Hash(400 + t * 16 + n, k), Hash(500 + t, k), 0, 61);
    if sign <> 0 then arr[at + z] := -v else arr[at + z] := v;
    Inc(nzCount); if nzCount > 3 then nzCount := 3;
    prevMag := MagBucket(v); if prevMag > 3 then prevMag := 3;
    Load(BANDS[n + 1], node);
    Inc(n);
  end;
  Result := 16;
end;

procedure ParseResiduals(var w: TWalk; var f: TFrame; p, mbx, mby: Integer; i4: Boolean;
                         var leftNz, leftNzDc: Byte);
var ctx, nz, x, y, ch, first, ac, l, gw: Integer; tnz, lnz, outT, outL: Byte;
    at, ab, lf: SizeInt;
  function YAt(bx, by: Integer): SizeInt;
  begin
    if (bx < 0) or (by < 0) then Exit(-1);
    Result := (SizeInt(by) * (f.mbw * 4) + bx) * 16;
  end;
  function CAt(bx, by: Integer): SizeInt;
  begin
    if (bx < 0) or (by < 0) then Exit(-1);
    Result := (SizeInt(by) * (f.mbw * 2) + bx) * 16;
  end;
begin
  if not i4 then begin
    ctx := f.topNzDc[mbx] + leftNzDc;
    at := (SizeInt(mby) * f.mbw + mbx) * 16;
    if mby > 0 then ab := at - SizeInt(f.mbw) * 16 else ab := -1;
    if mbx > 0 then lf := at - 16 else lf := -1;
    nz := GetCoeffs(w, f, p, 1, ctx, 0, f.cy2, at, ab, lf);
    f.topNzDc[mbx] := Ord(nz > 0); leftNzDc := Ord(nz > 0);
    first := 1; ac := 0;
  end else begin
    first := 0; ac := 3;
  end;
  tnz := f.topNz[mbx] and $0F;
  lnz := leftNz and $0F;
  for y := 0 to 3 do begin
    l := lnz and 1;
    for x := 0 to 3 do begin
      ctx := l + (tnz and 1);
      gw := mbx * 4 + x;
      at := YAt(gw, mby * 4 + y);
      nz := GetCoeffs(w, f, p, ac, ctx, first, f.cy, at, YAt(gw, mby * 4 + y - 1), YAt(gw - 1, mby * 4 + y));
      l := Ord(nz > first);
      tnz := ((tnz shr 1) or (l shl 7)) and $FF;
    end;
    tnz := tnz shr 4;
    lnz := ((lnz shr 1) or (l shl 7)) and $FF;
  end;
  outT := tnz;
  outL := lnz shr 4;
  for ch := 0 to 1 do begin
    tnz := (f.topNz[mbx] shr (4 + 2 * ch)) and $FF;
    lnz := (leftNz shr (4 + 2 * ch)) and $FF;
    for y := 0 to 1 do begin
      l := lnz and 1;
      for x := 0 to 1 do begin
        ctx := l + (tnz and 1);
        gw := mbx * 2 + x;
        at := CAt(gw, mby * 2 + y);
        if ch = 0 then
          nz := GetCoeffs(w, f, p, 2, ctx, 0, f.cu, at, CAt(gw, mby * 2 + y - 1), CAt(gw - 1, mby * 2 + y))
        else
          nz := GetCoeffs(w, f, p, 2, ctx, 0, f.cv, at, CAt(gw, mby * 2 + y - 1), CAt(gw - 1, mby * 2 + y));
        l := Ord(nz > 0);
        tnz := ((tnz shr 1) or (l shl 3)) and $FF;
      end;
      tnz := tnz shr 2;
      lnz := ((lnz shr 1) or (l shl 5)) and $FF;
    end;
    outT := (outT or ((tnz shl 4) shl (2 * ch))) and $FF;
    outL := (outL or ((lnz and $F0) shl (2 * ch))) and $FF;
  end;
  f.topNz[mbx] := outT;
  leftNz := outL;
end;

procedure WalkFrame(var w: TWalk);
var f: TFrame; tag, fps, width, height, i, j, k, c, q, ps, sizeLeft, mbx, mby, seg, part: Integer;
    v, ymode, uvmode, x, y: Integer; i4, skip: Boolean;
    leftModes: array[0..3] of Byte; leftNz, leftNzDc: Byte; leftI4, leftSkip: Integer;
    pr: array[0..8] of Integer; sizesAt, pos: SizeInt; top: Integer;
begin
  f := Default(TFrame);
  { the frame tag and the key frame header: plain bytes }
  for i := 0 to 9 do pr[0] := w.RawByte(i, i);
  if w.fail then Exit;
  if w.mode = MODE_DEC then begin
    tag := w.outp[0] or (w.outp[1] shl 8) or (w.outp[2] shl 16);
  end else tag := w.src[0] or (w.src[1] shl 8) or (w.src[2] shl 16);
  if (tag and 1) <> 0 then begin w.fail := True; Exit; end;         { not a key frame }
  if ((tag shr 1) and 7) > 3 then begin w.fail := True; Exit; end;
  if ((tag shr 4) and 1) = 0 then begin w.fail := True; Exit; end;
  fps := tag shr 5;
  if w.mode = MODE_DEC then begin
    if (w.outp[3] <> $9D) or (w.outp[4] <> $01) or (w.outp[5] <> $2A) then begin w.fail := True; Exit; end;
    width := (w.outp[6] or (w.outp[7] shl 8)) and $3FFF;
    height := (w.outp[8] or (w.outp[9] shl 8)) and $3FFF;
  end else begin
    if (w.src[3] <> $9D) or (w.src[4] <> $01) or (w.src[5] <> $2A) then begin w.fail := True; Exit; end;
    width := (w.src[6] or (w.src[7] shl 8)) and $3FFF;
    height := (w.src[8] or (w.src[9] shl 8)) and $3FFF;
  end;
  if (width < 1) or (height < 1) then begin w.fail := True; Exit; end;
  f.mbw := (width + 15) shr 4; f.mbh := (height + 15) shr 4;
  if SizeInt(f.mbw) * f.mbh > MAX_MBS then begin w.fail := True; Exit; end;
  if 10 + SizeInt(fps) > w.len then begin w.fail := True; Exit; end;
  w.parts[0].start := 10; w.parts[0].len := fps;
  if w.mode <> MODE_DEC then w.parts[0].dec.Init(w.src, 10, fps);
  if w.mode <> MODE_CHECK then w.parts[0].enc.Init;

  { the frame header }
  w.L(0, 1, 1); w.L(0, 1, 2);                               { colour space, clamping }
  f.useSeg := w.L(0, 1, 3) = 1;
  if f.useSeg then begin                                     { segments }
    f.updateMap := w.L(0, 1, 4) = 1;
    if w.L(0, 1, 5) = 1 then begin
      f.segAbs := w.L(0, 1, 6) = 1;
      for i := 0 to 3 do if w.L(0, 1, 7) = 1 then begin
        f.segQ[i] := w.L(0, 7, 8);
        if w.L(0, 1, 9) = 1 then f.segQ[i] := -f.segQ[i];
      end;
      for i := 0 to 3 do if w.L(0, 1, 10) = 1 then begin w.L(0, 6, 11); w.L(0, 1, 12); end;
    end;
    for i := 0 to 2 do f.segP[i] := 255;
    if f.updateMap then
      for i := 0 to 2 do if w.L(0, 1, 13) = 1 then f.segP[i] := w.L(0, 8, 14);
  end;
  w.L(0, 1, 15); w.L(0, 6, 16); w.L(0, 3, 17);              { filter }
  if w.L(0, 1, 18) = 1 then
    if w.L(0, 1, 19) = 1 then begin
      for i := 0 to 3 do if w.L(0, 1, 20) = 1 then begin w.L(0, 6, 21); w.L(0, 1, 22); end;
      for i := 0 to 3 do if w.L(0, 1, 23) = 1 then begin w.L(0, 6, 24); w.L(0, 1, 25); end;
    end;
  w.nparts := 1 shl w.L(0, 2, 26);
  if w.fail then Exit;
  { the token partitions' sizes: plain bytes after the first partition }
  sizesAt := 10 + SizeInt(fps);
  for i := 0 to 3 * (w.nparts - 1) - 1 do w.RawByte(sizesAt + i, 40 + i mod 3);
  if w.fail then Exit;
  pos := sizesAt + 3 * (w.nparts - 1);
  sizeLeft := w.len - pos;
  if sizeLeft < 0 then begin w.fail := True; Exit; end;
  for i := 0 to w.nparts - 2 do begin
    if w.mode = MODE_DEC then
      ps := w.outp[sizesAt + 3 * i] or (w.outp[sizesAt + 3 * i + 1] shl 8) or (w.outp[sizesAt + 3 * i + 2] shl 16)
    else
      ps := w.src[sizesAt + 3 * i] or (w.src[sizesAt + 3 * i + 1] shl 8) or (w.src[sizesAt + 3 * i + 2] shl 16);
    if ps > sizeLeft then ps := sizeLeft;
    w.parts[1 + i].start := pos; w.parts[1 + i].len := ps;
    pos := pos + ps; sizeLeft := sizeLeft - ps;
  end;
  w.parts[w.nparts].start := pos; w.parts[w.nparts].len := sizeLeft;
  if sizeLeft <= 0 then begin w.fail := True; Exit; end;
  for i := 1 to w.nparts do begin
    if w.mode <> MODE_DEC then w.parts[i].dec.Init(w.src, w.parts[i].start, w.parts[i].len);
    if w.mode <> MODE_CHECK then w.parts[i].enc.Init;
  end;
  { quantizers }
  f.baseQ := w.L(0, 7, 27);
  for i := 0 to 4 do if w.L(0, 1, 28 + i) = 1 then begin w.L(0, 4, 33 + i); w.L(0, 1, 38); end;
  w.L(0, 1, 39);                                             { refresh entropy probs }
  { coefficient probabilities }
  for i := 0 to 3 do
    for j := 0 to 7 do
      for k := 0 to 2 do
        for c := 0 to 10 do begin
          if w.BB(0, COEFFS_UPDATE_PROBA[i, j, k, c], Hash(5000 + i * 8 + j, k * 16 + c), 0, 0, 60) = 1 then
            f.probas[i, j, k, c] := w.L(0, 8, 50)
          else f.probas[i, j, k, c] := COEFFS_PROBA0[i, j, k, c];
        end;
  f.useSkip := w.L(0, 1, 51) = 1;
  if f.useSkip then f.skipP := w.L(0, 8, 52);
  if w.fail then Exit;

  { the macroblocks }
  SetLength(f.topNz, f.mbw); SetLength(f.topNzDc, f.mbw);
  SetLength(f.topModes, f.mbw * 4); SetLength(f.topI4, f.mbw); SetLength(f.topSkip, f.mbw);
  SetLength(f.cy, SizeInt(f.mbw) * f.mbh * 16 * 16);
  SetLength(f.cu, SizeInt(f.mbw) * f.mbh * 4 * 16);
  SetLength(f.cv, SizeInt(f.mbw) * f.mbh * 4 * 16);
  SetLength(f.cy2, SizeInt(f.mbw) * f.mbh * 16);
  for mby := 0 to f.mbh - 1 do begin
    FillChar(leftModes, SizeOf(leftModes), 0);
    leftNz := 0; leftNzDc := 0; leftI4 := 0; leftSkip := 0;
    part := 1 + (mby and (w.nparts - 1));
    for mbx := 0 to f.mbw - 1 do begin
      if w.fail then Exit;
      { segment }
      seg := 0;
      f.curQ := f.baseQ;
      if f.updateMap then begin
        if w.BB(0, f.segP[0], Hash(6000, 0), Hash(6001, seg), 0, 59) = 0 then
          seg := w.BB(0, f.segP[1], Hash(6000, 1), Hash(6001, 1), 0, 59)
        else seg := 2 + w.BB(0, f.segP[2], Hash(6000, 2), Hash(6001, 2), 0, 59);
      end;
      if f.useSeg then begin
        if f.segAbs then f.curQ := f.segQ[seg] else f.curQ := f.baseQ + f.segQ[seg];
        if f.curQ < 0 then f.curQ := 0 else if f.curQ > 127 then f.curQ := 127;
      end;
      skip := False;
      if f.useSkip then
        skip := w.BB(0, f.skipP, Hash(6100, leftSkip + f.topSkip[mbx]), Hash(6101, seg), 0, 58) = 1;
      i4 := w.BB(0, 145, Hash(6200, leftI4 + f.topI4[mbx]), Hash(6201, Ord(skip)), 0, 57) = 0;
      if not i4 then begin
        if w.BB(0, 156, Hash(6300, leftModes[0]), Hash(6301, f.topModes[mbx * 4]), 0, 56) = 1 then begin
          if w.BB(0, 128, Hash(6310, leftModes[0]), Hash(6311, f.topModes[mbx * 4]), 0, 56) = 1 then ymode := 1 { TM }
          else ymode := 3;                                                    { H }
        end else begin
          if w.BB(0, 163, Hash(6320, leftModes[0]), Hash(6321, f.topModes[mbx * 4]), 0, 56) = 1 then ymode := 2 { V }
          else ymode := 0;                                                    { DC }
        end;
        for i := 0 to 3 do begin f.topModes[mbx * 4 + i] := ymode; leftModes[i] := ymode; end;
      end else begin
        for y := 0 to 3 do begin
          v := leftModes[y];
          for x := 0 to 3 do begin
            top := f.topModes[mbx * 4 + x];
            { the 4x4 mode tree, as libwebp walks it }
            if w.BB(0, BMODES_PROBA[top, v, 0], Hash(6400 + top, v * 16), Hash(6500, y * 4 + x), 0, 55) = 0 then v := 0
            else if w.BB(0, BMODES_PROBA[top, v, 1], Hash(6400 + top, v * 16 + 1), Hash(6500, 1), 0, 55) = 0 then v := 1
            else if w.BB(0, BMODES_PROBA[top, v, 2], Hash(6400 + top, v * 16 + 2), Hash(6500, 2), 0, 55) = 0 then v := 2
            else if w.BB(0, BMODES_PROBA[top, v, 3], Hash(6400 + top, v * 16 + 3), Hash(6500, 3), 0, 55) = 0 then begin
              if w.BB(0, BMODES_PROBA[top, v, 4], Hash(6400 + top, v * 16 + 4), Hash(6500, 4), 0, 55) = 0 then v := 3
              else if w.BB(0, BMODES_PROBA[top, v, 5], Hash(6400 + top, v * 16 + 5), Hash(6500, 5), 0, 55) = 0 then v := 4
              else v := 5;
            end else begin
              if w.BB(0, BMODES_PROBA[top, v, 6], Hash(6400 + top, v * 16 + 6), Hash(6500, 6), 0, 55) = 0 then v := 6
              else if w.BB(0, BMODES_PROBA[top, v, 7], Hash(6400 + top, v * 16 + 7), Hash(6500, 7), 0, 55) = 0 then v := 7
              else if w.BB(0, BMODES_PROBA[top, v, 8], Hash(6400 + top, v * 16 + 8), Hash(6500, 8), 0, 55) = 0 then v := 8
              else v := 9;
            end;
            f.topModes[mbx * 4 + x] := v;
          end;
          leftModes[y] := v;
        end;
        ymode := 10;
      end;
      { chroma mode }
      uvmode := 0;
      if w.BB(0, 142, Hash(6600, ymode), 0, 0, 54) = 1 then
        if w.BB(0, 114, Hash(6601, ymode), 0, 0, 54) = 1 then
          uvmode := w.BB(0, 183, Hash(6602, ymode), 0, 0, 54);
      if uvmode = 0 then ;
      f.topI4[mbx] := Ord(i4); leftI4 := Ord(i4);
      f.topSkip[mbx] := Ord(skip); leftSkip := Ord(skip);
      { the coefficients }
      if not skip then
        ParseResiduals(w, f, part, mbx, mby, i4, leftNz, leftNzDc)
      else begin
        leftNz := 0; f.topNz[mbx] := 0;
        if not i4 then begin leftNzDc := 0; f.topNzDc[mbx] := 0; end;
      end;
    end;
  end;
end;

{ After the walk: each partition's end, as the stream had it. }
procedure CloseParts(var w: TWalk);
var i, last: Integer; ours: TBytes; L, k, tail: SizeInt;
begin
  for i := 0 to w.nparts do begin
    if w.fail then Exit;
    if w.mode = MODE_CHECK then Continue;
    L := 0;
    ours := w.parts[i].enc.Finish;
    if w.mode = MODE_ENC then begin
      L := 0;
      while (L < w.parts[i].len) and (L < Length(ours)) and
            (ours[L] = w.src[w.parts[i].start + L]) do Inc(L);
      tail := w.parts[i].len - L;
    end else tail := 0;
    { the tail's length, as 24 bits (a partition is at most 2^19 bytes in
      the first, 2^24 in the others) }
    if w.mode = MODE_ENC then begin
      for k := 23 downto 0 do
        w.m.CodeBit(w.cd, (tail shr k) and 1, 128, Hash(7000, k), Hash(7001, tail shr (k + 1)), 0, 53);
    end else begin
      tail := 0;
      for k := 23 downto 0 do
        tail := tail or (SizeInt(w.m.CodeBit(w.cd, 0, 128, Hash(7000, k), Hash(7001, tail shr (k + 1)), 0, 53)) shl k);
      if tail > w.parts[i].len then begin w.fail := True; Exit; end;
      L := w.parts[i].len - tail;
      if L > Length(ours) then begin w.fail := True; Exit; end;
      if L > 0 then Move(ours[0], w.outp[w.parts[i].start], L);
    end;
    last := 0;
    for k := w.parts[i].start + L to w.parts[i].start + w.parts[i].len - 1 do
      last := w.RawByte(k, 60 + Ord(last = 0));
  end;
end;

{ ---------------- finding the streams ---------------- }

function Le32(const d: TBytes; p: SizeInt): Int64; inline;
begin
  Result := Int64(d[p]) or (Int64(d[p + 1]) shl 8) or (Int64(d[p + 2]) shl 16)
            or (Int64(d[p + 3]) shl 24);
end;

function IsId(const d: TBytes; p: SizeInt; const id: string): Boolean;
begin
  Result := (p + 4 <= Length(d)) and (d[p] = Ord(id[1])) and (d[p + 1] = Ord(id[2]))
    and (d[p + 2] = Ord(id[3])) and (d[p + 3] = Ord(id[4]));
end;

function CheckStream(const d: TBytes; a, b: SizeInt): Boolean;
var w: TWalk;
begin
  w := Default(TWalk);
  w.mode := MODE_CHECK;
  w.src := Copy(d, a, b - a);
  w.len := b - a;
  if w.len < 10 then Exit(False);
  WalkFrame(w);
  Result := not w.fail;
end;

procedure Walk(const d: TBytes; q, stop: SizeInt; var r: TVp8Streams; var n: Integer; depth: Integer);
var sz: Int64;   { 32-bit size: Int64, no wrap on i386 } s: TVp8Stream;
begin
  while q + 8 <= stop do begin
    sz := Le32(d, q + 4);
    if q + 8 + sz > stop then Exit;
    if IsId(d, q, 'ANMF') and (sz >= 16) and (depth = 0) then
      Walk(d, q + 8 + 16, q + 8 + sz, r, n, 1)
    else if IsId(d, q, 'VP8 ') and CheckStream(d, q + 8, q + 8 + sz) then begin
      s.dataStart := q + 8; s.dataEnd := q + 8 + sz;
      if n >= Length(r) then SetLength(r, n * 2 + 8);
      r[n] := s; Inc(n);
    end;
    q := q + 8 + sz + (sz and 1);
  end;
end;

function FindVp8Streams(const d: TBytes): TVp8Streams;
var n: Integer; stop: Int64;
begin
  Result := nil; n := 0;
  if (Length(d) < 12) or not IsId(d, 0, 'RIFF') or not IsId(d, 8, 'WEBP') then Exit;
  stop := 8 + Le32(d, 4);
  if stop > Length(d) then stop := Length(d);
  Walk(d, 12, stop, Result, n, 0);
  SetLength(Result, n);
end;

{ ---------------- coding ---------------- }

procedure CodeVp8Stream(cd: TCoder; m: TVp8Model; var data: TBytes; len: SizeInt);
var w: TWalk;
begin
  w := Default(TWalk);
  w.cd := cd; w.m := m; w.len := len;
  if cd.encoding then begin
    w.mode := MODE_ENC; w.src := data;
  end else begin
    w.mode := MODE_DEC; w.outp := nil; SetLength(w.outp, len);
  end;
  WalkFrame(w);
  CloseParts(w);
  if w.fail then raise Exception.Create('paia8vp8: a stream that does not walk');
  if not cd.encoding then data := w.outp;
end;

end.
