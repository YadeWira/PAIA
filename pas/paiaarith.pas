{ Codec layer: binary arithmetic coder, counters, a logistic mixer and an
  adaptive probability map.

  Integer only, so every platform and compiler gives the same bytes.

  The coder is carryless, with the interval in 32 bits [x1, x2] (the lpaq
  form): whenever both ends agree on the top byte, that byte is emitted.
  Probabilities are 12 bits: p = P(bit = 1) * 4096, in [1, 4095].

  The decoder cannot fail: past the end of its data it reads zeros. A
  damaged stream decodes to something else, and that is caught by the layer
  above (size and hash of the original), not by this one. }
unit paiaarith;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiaarith: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiaarith: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

type
  TArithEncoder = record
    x1, x2: LongWord;
    d: TBytes;
    n: SizeInt;
    procedure Init;
    procedure Encode(bit: Integer; p12: Integer);
    function Finish: TBytes;
  end;

  TArithDecoder = record
    x1, x2, x: LongWord;
    d: TBytes;
    p, last: SizeInt;
    procedure Init(const data: TBytes; first, len: SizeInt);
    function Decode(p12: Integer): Integer;
  end;

  { One side of a coding session: the same model code drives both. }
  TCoder = class
  public
    encoding: Boolean;
    enc: TArithEncoder;
    dec: TArithDecoder;
    constructor CreateEncoder;
    constructor CreateDecoder(const data: TBytes; first, len: SizeInt);
    { encoding: codes `bit` and returns it; decoding: returns the bit }
    function Code(bit: Integer; p12: Integer): Integer; inline;
  end;

{ ln(p / (1 - p)) scaled to [-2047, 2047], for p in 12 bits; and back. }
function Stretch(p12: Integer): Integer; inline;
function Squash(x: Integer): Integer;

type
  { Adaptive probabilities: 16 bits each, the rate slowing from 1/2 to
    1/(limit + 2) as each one sees more. One 32-bit word each: the
    probability (xor 1/2, so that a zeroed table is all 1/2) in the high
    half, the count in the low one. }
  TCounters = record
    e: array of LongWord;
    mask: SizeInt;
    limit: Integer;
    procedure Init(bits: Integer; aLimit: Integer);
    function P12(i: SizeInt): Integer; inline;
    procedure Update(i: SizeInt; bit: Integer); inline;
  end;

  { A logistic mixer: several stretched predictions, one weight set chosen
    by a small context, trained on the coding error. }
  TMixer = record
    nIn, nSets: Integer;
    w: array of LongInt;
    x: array of LongInt;
    k, cur, pr, rate: Integer;
    procedure Init(inputs, sets, aRate: Integer);
    procedure Add(st: Integer); inline;
    function Mix(ctx: Integer): Integer;
    procedure Update(bit: Integer);
  end;

  { An adaptive probability map (secondary estimation): refines a
    probability given a context, interpolating between 33 buckets. }
  TApm = record
    t: array of LongInt;      { minus the initial curve: zeroed = initial }
    idx: SizeInt;
    bucket, rate: Integer;
    procedure Init(contexts: SizeInt; aRate: Integer);
    function Refine(p12: Integer; ctx: SizeInt): Integer;
    procedure Update(bit: Integer);
  end;

type
  { A match model (as lpaq's): the longest earlier occurrence of the last
    MINLEN bytes coded predicts the bytes that follow it. The caller turns
    the expected byte into a prediction per bit (Input / Learn). }
  TMatchModel = record
    hist: TBytes;
    n: SizeInt;
    ht: array of LongInt;
    hmask: SizeInt;
    ptr: SizeInt;              { where the expected byte is, if len > 0 }
    len: Integer;
    sm: TCounters;             { by length and expected bit }
    cur: SizeInt;
    procedure Init(hashBits: Integer);
    { the byte expected k bytes ahead, or -1 }
    function Expected(k: Integer): Integer; inline;
    { the stretched prediction for the next bit, given the expected value
      `e` (-1: none) of `bits` bits, the bits so far `node` (with its
      leading 1) and the bit's place b }
    function Input(e, bits, node, b: Integer): Integer;
    procedure Learn(bit: Integer); inline;
    procedure Update(c: Byte);
  end;

{ The tables, also handed to the C model (paiapix.c) so that both use the
  very same numbers. }
var
  stretchTab: array[0..4095] of SmallInt;
  squashTab: array[0..4095] of SmallInt;
  apmBase: array[0..32] of LongInt;
  rateTab: array[0..1023] of LongInt;

implementation

function SquashCalc(x: Integer): Integer;
const t: array[0..32] of Integer = (
  1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194, 310, 488, 747, 1101,
  1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901, 3975, 4024,
  4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094);
var v, i, w: Integer;
begin
  if x > 2047 then Exit(4095);
  if x < -2047 then Exit(1);
  v := x + 2048;                     { 1 .. 4095 }
  i := v shr 7;                      { 0 .. 31 }
  w := v and 127;
  Result := (t[i] * (128 - w) + t[i + 1] * w + 64) shr 7;
  if Result < 1 then Result := 1;
  if Result > 4095 then Result := 4095;
end;

function Squash(x: Integer): Integer;
begin
  if x > 2047 then Exit(4095);
  if x < -2047 then Exit(1);
  Result := squashTab[x + 2048];
end;

function Stretch(p12: Integer): Integer; inline;
begin
  Result := stretchTab[p12];
end;

procedure BuildTables;
var x, pi, v, j: Integer;
begin
  for x := -2048 to 2047 do squashTab[x + 2048] := SquashCalc(x);
  { the inverse of Squash: for each p, the x whose squash first reaches p }
  pi := 0;
  for x := -2047 to 2047 do begin
    v := Squash(x);
    for j := pi to v do stretchTab[j] := x;
    if v + 1 > pi then pi := v + 1;
  end;
  for j := pi to 4095 do stretchTab[j] := 2047;
  for j := 0 to 1023 do rateTab[j] := 65536 div (j + 2);
  for j := 0 to 32 do apmBase[j] := SquashCalc((j - 16) * 128) * 16;
end;

{ ---------------- coder ---------------- }

procedure TArithEncoder.Init;
begin
  x1 := 0; x2 := $FFFFFFFF; d := nil; SetLength(d, 4096); n := 0;
end;

procedure TArithEncoder.Encode(bit: Integer; p12: Integer);
var xmid: LongWord;
begin
  xmid := x1 + LongWord((QWord(x2 - x1) * LongWord(p12)) shr 12);
  if bit <> 0 then x2 := xmid else x1 := xmid + 1;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    if n >= Length(d) then SetLength(d, Length(d) * 2);
    d[n] := Byte(x2 shr 24); Inc(n);
    x1 := LongWord(x1 shl 8);
    x2 := LongWord(x2 shl 8) or 255;
  end;
end;

function TArithEncoder.Finish: TBytes;
var i: Integer;
begin
  { x1's bytes: the decoder reads zeros after them, which stays in range }
  for i := 0 to 3 do begin
    if n >= Length(d) then SetLength(d, Length(d) * 2);
    d[n] := Byte(x1 shr 24); Inc(n);
    x1 := LongWord(x1 shl 8);
  end;
  SetLength(d, n);
  Result := d;
end;

procedure TArithDecoder.Init(const data: TBytes; first, len: SizeInt);
var i: Integer;
begin
  if (first < 0) or (len < 0) or (first + len > Length(data)) then
    raise ERangeError.Create('paiaarith: range outside the data');
  d := data; p := first; last := first + len;
  x1 := 0; x2 := $FFFFFFFF; x := 0;
  for i := 0 to 3 do begin
    x := LongWord(x shl 8);
    if p < last then begin x := x or d[p]; Inc(p); end;
  end;
end;

function TArithDecoder.Decode(p12: Integer): Integer;
var xmid: LongWord;
begin
  xmid := x1 + LongWord((QWord(x2 - x1) * LongWord(p12)) shr 12);
  if x <= xmid then begin Result := 1; x2 := xmid; end
  else begin Result := 0; x1 := xmid + 1; end;
  while ((x1 xor x2) and $FF000000) = 0 do begin
    x1 := LongWord(x1 shl 8);
    x2 := LongWord(x2 shl 8) or 255;
    x := LongWord(x shl 8);
    if p < last then begin x := x or d[p]; Inc(p); end;
  end;
end;

constructor TCoder.CreateEncoder;
begin
  inherited Create;
  encoding := True;
  enc.Init;
end;

constructor TCoder.CreateDecoder(const data: TBytes; first, len: SizeInt);
begin
  inherited Create;
  encoding := False;
  dec.Init(data, first, len);
end;

function TCoder.Code(bit: Integer; p12: Integer): Integer; inline;
begin
  if p12 < 1 then p12 := 1 else if p12 > 4095 then p12 := 4095;
  if encoding then begin enc.Encode(bit, p12); Result := bit; end
  else Result := dec.Decode(p12);
end;

{ ---------------- counters ---------------- }

procedure TCounters.Init(bits: Integer; aLimit: Integer);
begin
  e := nil;
  SetLength(e, SizeInt(1) shl bits);     { zeroed: every one at 1/2 }
  mask := (SizeInt(1) shl bits) - 1;
  limit := aLimit;
end;

function TCounters.P12(i: SizeInt): Integer; inline;
begin
  Result := ((e[i] shr 16) xor $8000) shr 4;
end;

procedure TCounters.Update(i: SizeInt; bit: Integer); inline;
var c: Integer; v: LongInt; x: LongWord;
begin
  x := e[i];
  c := x and $FFFF;
  v := (x shr 16) xor $8000;
  if bit <> 0 then v := v + (((65535 - v) * rateTab[c]) shr 16)
  else v := v - ((v * rateTab[c]) shr 16);
  if v < 32 then v := 32 else if v > 65503 then v := 65503;
  if c < limit then Inc(c);
  e[i] := (LongWord(v xor $8000) shl 16) or LongWord(c);
end;

{ ---------------- mixer ---------------- }

procedure TMixer.Init(inputs, sets, aRate: Integer);
var i: Integer;
begin
  nIn := inputs; nSets := sets; rate := aRate;
  w := nil; x := nil;
  SetLength(w, inputs * sets);
  SetLength(x, inputs);
  for i := 0 to High(w) do w[i] := 65536 div inputs;
  k := 0; cur := 0; pr := 2048;
end;

procedure TMixer.Add(st: Integer); inline;
begin
  x[k] := st; Inc(k);
end;

function TMixer.Mix(ctx: Integer): Integer;
var i: Integer; dot: Int64;
begin
  cur := ctx * nIn;
  dot := 0;
  for i := 0 to k - 1 do dot := dot + Int64(x[i]) * w[cur + i];
  { weights are 16.16: the mixed stretch is dot / 65536 }
  dot := SarInt64(dot, 16);
  if dot > 2047 then dot := 2047 else if dot < -2047 then dot := -2047;
  pr := Squash(Integer(dot));
  Result := pr;
end;

procedure TMixer.Update(bit: Integer);
var i, err: Integer; v: LongInt;
begin
  err := ((bit shl 12) - pr) * rate;
  for i := 0 to k - 1 do begin
    v := w[cur + i] + SarLongint(x[i] * err, 10);
    if v > 16777216 then v := 16777216 else if v < -16777216 then v := -16777216;
    w[cur + i] := v;
  end;
  k := 0;
end;

{ ---------------- APM ---------------- }

procedure TApm.Init(contexts: SizeInt; aRate: Integer);
begin
  t := nil;
  SetLength(t, contexts * 33);
  rate := aRate; idx := 0;
end;

function TApm.Refine(p12: Integer; ctx: SizeInt): Integer;
var s, w: Integer;
begin
  s := Stretch(p12) + 2048;          { 1 .. 4095 }
  w := s and 127;
  idx := ctx * 33 + (s shr 7);
  Result := ((t[idx] + apmBase[s shr 7]) * (128 - w)
             + (t[idx + 1] + apmBase[(s shr 7) + 1]) * w) shr 11;
  bucket := s shr 7;
  if w >= 64 then begin Inc(idx); Inc(bucket); end;          { the nearer bucket learns }
  if Result < 1 then Result := 1 else if Result > 4095 then Result := 4095;
end;

procedure TApm.Update(bit: Integer);
var g, v: LongInt;
begin
  g := (bit shl 16) + (bit shl rate) - bit - bit;
  v := t[idx] + apmBase[bucket];
  t[idx] := t[idx] + SarLongint(g - v, rate);
end;

{ ---------------- match model ---------------- }

const MINLEN = 5;

procedure TMatchModel.Init(hashBits: Integer);
begin
  hist := nil; SetLength(hist, 1 shl 16); n := 0;
  ht := nil; SetLength(ht, SizeInt(1) shl hashBits);
  hmask := (SizeInt(1) shl hashBits) - 1;
  ptr := 0; len := 0;
  sm.Init(7, 1023);
  cur := 0;
end;

function TMatchModel.Expected(k: Integer): Integer; inline;
begin
  if (len > 0) and (ptr + k < n) then Result := hist[ptr + k] else Result := -1;
end;

function TMatchModel.Input(e, bits, node, b: Integer): Integer;
var l: Integer;
begin
  if (e >= 0) and (((e or (1 shl bits)) shr (b + 1)) = node) then begin
    l := len; if l > 31 then l := 31;
    cur := 2 + l * 2 + ((e shr b) and 1);
  end else cur := 0;
  Result := Stretch(sm.P12(cur));
end;

procedure TMatchModel.Learn(bit: Integer); inline;
begin
  sm.Update(cur, bit);
end;

procedure TMatchModel.Update(c: Byte);
var h: QWord; i: Integer;
begin
  if n >= Length(hist) then SetLength(hist, Length(hist) * 2);
  hist[n] := c; Inc(n);
  if (len > 0) and (hist[ptr] = c) then begin
    Inc(ptr); if len < 65535 then Inc(len);
  end else len := 0;
  if n >= MINLEN then begin
    h := 0;
    for i := 1 to MINLEN do h := ((h * 773) + hist[n - i] + 1) and $FFFFFFFF;
    h := (h * QWord($9E3779B1)) and $FFFFFFFF;
    h := h shr 8;
    if len = 0 then
      if ht[h and hmask] > 0 then begin ptr := ht[h and hmask]; len := 1; end;
    ht[h and hmask] := n;
  end;
end;

initialization
  BuildTables;
end.
