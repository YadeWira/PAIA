{ FLIF (Free Lossless Image Format, FLIF16): replaying a file's coding
  decisions.

  A FLIF is a header, then one range-coded stream (24-bit RAC) of binary
  decisions, each with a 12-bit chance its own model gave it. PAIA does not
  decode the pixels to code them again with a model of its own: it runs
  FLIF's decoder, and each decision, with FLIF's chance for it, is coded
  by PAIA's model (TFlifBits.Decide, implemented by paiacodec). On the way
  back the same decoder runs on the decisions PAIA's model gives back, and
  each is written with a range coder that is the exact inverse of FLIF's
  (TFlifRacOut): the stream comes back byte for byte, whatever its
  content. The decoder only has to find, at each step, the same chance as
  FLIF's: it does not undo the colour transforms or build the RGBA image.

  The decoder follows FLIF's reference implementation (flif-dec.cpp and
  the decoder side of maniac/ and transform/, Apache 2.0, copyright 2010-
  2016 Jon Sneyers & Pieter Wuille; see NOTICE): the chance tables, the
  symbol coder, the MANIAC trees, the ten transforms' parameters and colour
  ranges, and the interlaced and scanline orders, with animations. The
  range encoder is written here as the inverse of FLIF's decoder.

  Exactness does not depend on this decoder being right: compressing and
  decompressing run the same code. Only the compression does: a chance
  that differs from FLIF's is a worse prediction. tests/tools has a check
  against the reference decoder's own chances.

  No Int64 loop counters (i386 FreePascal refuses them). }
unit paiaflif;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiaflif: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiaflif: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith;

const
  { what a decision is, for the models of the caller (TFlifBits.kind) }
  FD_UNIFORM = 0;      { a uniform bit (header integers) }
  FD_ZERO = 1;         { a symbol's zero bit }
  FD_SIGN = 2;
  FD_EXP = 3;          { an exponent bit (index in TFlifBits.idx) }
  FD_MANT = 4;         { a mantissa bit }
  { where: TFlifBits.part }
  FP_HEADER = 0;       { header, transforms' parameters }
  FP_TREE = 1;         { the MANIAC trees }
  FP_PIXEL = 2;        { pixel values }

type
  EFlif = class(Exception);

  { The source (or sink) of the decisions. The decoder sets the fields that
    describe the decision, then asks for the bit. }
  TFlifBits = class
  public
    kind, idx, part, plane, zoom: Integer;
    guess: Integer;              { a pixel's prediction (part FP_PIXEL) }
    count: Int64;                { decisions so far }
    { b12: FLIF's chance of a 1, 1..4095 (12 bits); uniform: a fair bit }
    function Decide(b12: Integer): Boolean; virtual; abstract;
    function Uniform: Boolean; virtual; abstract;
  end;

  { FLIF's range decoder (24-bit RAC) over a stream. }
  TFlifRacIn = class
  private
    d: TBytes;
    pos, len: SizeInt;
    range, low: Int64;
    function NextByte: Int64;
    procedure Refill;
  public
    constructor Create(const data: TBytes; start, stop: SizeInt);
    function Get(chance: Int64): Boolean;
    function Get12(b12: Integer): Boolean;
    function GetHalf: Boolean;
    { bytes read so far, from start }
    function Consumed: SizeInt;
    property CurRange: Int64 read range;
  end;

  { The exact inverse: the same decisions with the same chances give the
    same bytes. Bytes whose value a later carry could still change are
    pending (Determined tells how many are final). }
  TFlifRacOut = class
  private
    range, low: Int64;
    cache, ffs: Integer;
    hasCache: Boolean;
    procedure ShiftLow;
    procedure Emit(b: Integer);
  public
    outBuf: TBytes;
    outLen: SizeInt;
    constructor Create;
    procedure Put(bit: Boolean; chance: Int64);
    procedure Put12(bit: Boolean; b12: Integer);
    procedure PutHalf(bit: Boolean);
  end;

  { The header, as far as the decoder needs it. }
  TFlifHeader = record
    numPlanes: Integer;   { 1, 3 or 4 }
    depthChar: Integer;   { '0', '1' or '2' }
    width, height: Integer;
    numFrames: Integer;
    interlaced: Boolean;
    racStart: SizeInt;    { where the range-coded stream starts }
  end;

  { a FLIF's range-coded stream, as paiacodec takes it }
  TFlifStream = record
    dataStart, dataEnd: SizeInt;
    hdr: TFlifHeader;
  end;

  { PAIA's model of FLIF's decisions: FLIF's own chance, and what the
    decision is (its part, kind, plane, zoom level, the pixel's guess),
    mixed }
  TFlifModel = class
  private
    t: array[0..5] of TCounters;
    mx: TMixer;
    apm: TApm;
    hist: Integer;
  public
    constructor Create(tableBits: Integer);
    function Code(cd: TCoder; bit, b12: Integer; src: TFlifBits): Integer;
  end;

{ The header of the FLIF at the start of d (its metadata chunks skipped). }
function ParseFlifHeader(const d: TBytes; out h: TFlifHeader): Boolean;

{ A FLIF at the start of d whose decisions this decoder replays and whose
  stream TFlifRacOut gives back byte for byte (but its last few bytes,
  which CodeFlifStream keeps as they are). }
function FindFlifStream(const d: TBytes; out s: TFlifStream): Boolean;

{ Codes a FLIF stream's data (decoding: rebuilds it, `len` bytes). }
procedure CodeFlifStream(cd: TCoder; m: TFlifModel; const h: TFlifHeader; var data: TBytes; len: SizeInt);

{ Runs FLIF's decoder on the decisions `bits` gives, to the end of the
  stream; raises EFlif on a stream it cannot follow. }
procedure ReplayFlif(const h: TFlifHeader; bits: TFlifBits);

implementation

uses Math;

{ ---------------- the range coder ---------------- }

const
  MAX_RANGE_BITS = 24;
  MIN_RANGE = Int64(1) shl 16;
  BASE_RANGE = Int64(1) shl MAX_RANGE_BITS;

constructor TFlifRacIn.Create(const data: TBytes; start, stop: SizeInt);
var k: Integer;
begin
  inherited Create;
  d := data; pos := start; len := stop;
  range := BASE_RANGE; low := 0;
  for k := 1 to 3 do low := (low shl 8) or NextByte;
end;

function TFlifRacIn.NextByte: Int64;
begin
  if pos >= len then raise EFlif.Create('flif: the stream ends early');
  Result := d[pos];
  Inc(pos);
end;

procedure TFlifRacIn.Refill;
begin
  if range <= MIN_RANGE then begin
    low := (low shl 8) or NextByte;
    range := range shl 8;
  end;
  if range <= MIN_RANGE then begin
    low := (low shl 8) or NextByte;
    range := range shl 8;
  end;
end;

function TFlifRacIn.Get(chance: Int64): Boolean;
begin
  if (chance <= 0) or (chance >= range) then raise EFlif.Create('flif: damaged stream');
  if low >= range - chance then begin
    low := low - (range - chance);
    range := chance;
    Result := True;
  end else begin
    range := range - chance;
    Result := False;
  end;
  Refill;
end;

function TFlifRacIn.Get12(b12: Integer): Boolean;
begin
  Result := Get((range * b12 + $800) shr 12);
end;

function TFlifRacIn.GetHalf: Boolean;
begin
  Result := Get(range shr 1);
end;

function TFlifRacIn.Consumed: SizeInt;
begin
  Result := pos;
end;

constructor TFlifRacOut.Create;
begin
  inherited Create;
  range := BASE_RANGE; low := 0;
  hasCache := False; cache := 0; ffs := 0;
  outBuf := nil; outLen := 0;
end;

procedure TFlifRacOut.Emit(b: Integer);
begin
  if outLen >= Length(outBuf) then SetLength(outBuf, outLen * 2 + 4096);
  outBuf[outLen] := b and 255;
  Inc(outLen);
end;

{ the window's top byte (bits 16 to 23) leaves; a carry (bit 24) adds to
  the bytes already out, so a byte is written only once no carry can reach
  it: the last one, and a run of 0xFF after it, wait }
procedure TFlifRacOut.ShiftLow;
var carry: Integer;
begin
  if (low shr 16) <> $FF then begin
    carry := Integer(low shr 24);
    if hasCache then Emit(cache + carry)
    else if carry <> 0 then raise EFlif.Create('flif: carry out of the stream');
    while ffs > 0 do begin Emit($FF + carry); Dec(ffs); end;
    cache := Integer((low shr 16) and $FF);
    hasCache := True;
  end else
    Inc(ffs);
  low := (low and $FFFF) shl 8;
end;

procedure TFlifRacOut.Put(bit: Boolean; chance: Int64);
begin
  if bit then begin
    low := low + (range - chance);
    range := chance;
  end else
    range := range - chance;
  while range <= MIN_RANGE do begin
    ShiftLow;
    range := range shl 8;
  end;
end;

procedure TFlifRacOut.Put12(bit: Boolean; b12: Integer);
begin
  Put(bit, (range * b12 + $800) shr 12);
end;

procedure TFlifRacOut.PutHalf(bit: Boolean);
begin
  Put(bit, range shr 1);
end;

{ ---------------- the chances ---------------- }

type
  { SimpleBitChanceTable: a chance's next value after a 0 and after a 1 }
  TChanceTable = class
    next: array[0..1, 0..4095] of Word;
    constructor Create(cut: Integer; alpha: Int64);
  end;

{ build_table: FLIF's adaptation steps for a factor (alpha / 2^32) and a
  cut (chances stay within cut..4096-cut) }
constructor TChanceTable.Create(cut: Integer; alpha: Int64);
const SIZE = 4096; ONE = Int64(1) shl 32;
var p: Int64; lastP8, p8, maxP, i: Integer;
begin
  inherited Create;
  FillChar(next, SizeOf(next), 0);
  maxP := SIZE - cut;
  lastP8 := 0;
  p := ONE div 2;
  for i := 0 to SIZE div 2 - 1 do begin
    p8 := Integer((SIZE * p + ONE div 2) shr 32);
    if p8 <= lastP8 then p8 := lastP8 + 1;
    if (lastP8 <> 0) and (lastP8 < SIZE) and (p8 <= maxP) then next[1][lastP8] := p8;
    p := p + (((ONE - p) * alpha + ONE div 2) shr 32);
    lastP8 := p8;
  end;
  for i := SIZE - maxP to maxP do begin
    if next[1][i] <> 0 then Continue;
    p := (Int64(i) * ONE + SIZE div 2) div SIZE;
    p := p + (((ONE - p) * alpha + ONE div 2) shr 32);
    p8 := Integer((SIZE * p + ONE div 2) shr 32);
    if p8 <= i then p8 := i + 1;
    if p8 > maxP then p8 := maxP;
    next[1][i] := p8;
  end;
  for i := 1 to SIZE - 1 do next[0][i] := SIZE - next[1][SIZE - i];
end;

const
  EXP_CHANCES: array[0..16] of Word = (1000, 1200, 1500, 1750, 2000, 2300, 2800, 2400, 2300,
                                       2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048);
  MANT_CHANCES: array[0..17] of Word = (1900, 1850, 1800, 1750, 1650, 1600, 1600, 2048, 2048,
                                        2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048, 2048);
  ZERO_CHANCE = 1000;
  SIGN_CHANCE = 2048;

type
  { SymbolChance<bits>: the chances of one integer's bits }
  TSymbolChance = record
    zero, sign: Word;
    exp: array[0..33] of Word;    { 2 * (bits - 1) }
    mant: array[0..17] of Word;   { bits }
  end;
  PSymbolChance = ^TSymbolChance;

procedure InitSymbolChance(var s: TSymbolChance; bits: Integer);
var i: Integer;
begin
  FillChar(s, SizeOf(s), 0);
  s.zero := ZERO_CHANCE;
  s.sign := SIGN_CHANCE;
  for i := 0 to bits - 2 do begin
    s.exp[2 * i] := EXP_CHANCES[i];
    s.exp[2 * i + 1] := EXP_CHANCES[i];
  end;
  for i := 0 to bits - 1 do s.mant[i] := MANT_CHANCES[i];
end;

function ILog2(x: Int64): Integer;
begin
  Result := 0;
  while x > 1 do begin x := x shr 1; Inc(Result); end;
end;

{ one decision with a chance from `ch`, which then adapts }
function ReadChance(bits: TFlifBits; var ch: Word; table: TChanceTable; kind, idx: Integer): Boolean;
begin
  bits.kind := kind; bits.idx := idx;
  Result := bits.Decide(ch);
  ch := table.next[Ord(Result)][ch];
end;

{ reader<bits>(coder, min, max): FLIF's integer, zero, sign, exponent and
  mantissa bits }
function ReadSymbol(bits: TFlifBits; var s: TSymbolChance; table: TChanceTable; nbits, vmin, vmax: Integer): Integer;
var sign: Boolean; amax, emax, e, have, left, pos, minabs1, maxabs0, si: Integer;
begin
  if vmin > vmax then raise EFlif.Create('flif: damaged stream');
  if vmin = vmax then Exit(vmin);
  if (vmin > 0) or (vmax < 0) then raise EFlif.Create('flif: damaged stream');
  if ReadChance(bits, s.zero, table, FD_ZERO, 0) then Exit(0);
  if vmin < 0 then begin
    if vmax > 0 then sign := ReadChance(bits, s.sign, table, FD_SIGN, 0)
    else sign := False;
  end else sign := True;
  if sign then amax := vmax else amax := -vmin;
  emax := ILog2(amax);
  e := 0;
  si := Ord(sign);
  while e < emax do begin
    if 2 * e + si > High(s.exp) then raise EFlif.Create('flif: damaged stream');
    if ReadChance(bits, s.exp[2 * e + si], table, FD_EXP, 2 * e + si) then Break;
    Inc(e);
  end;
  have := 1 shl e;
  left := have - 1;
  pos := e;
  while pos > 0 do begin
    left := left shr 1; Dec(pos);
    minabs1 := have or (1 shl pos);
    maxabs0 := have or left;
    if minabs1 > amax then Continue
    else if maxabs0 >= 1 then begin
      if pos > High(s.mant) then raise EFlif.Create('flif: damaged stream');
      if ReadChance(bits, s.mant[pos], table, FD_MANT, pos) then have := minabs1;
    end else
      have := minabs1;
  end;
  if sign then Result := have else Result := -have;
end;

{ SimpleSymbolCoder: an integer with chances of its own }
type
  TSimpleCoder = class
    s: TSymbolChance;
    table: TChanceTable;
    nbits: Integer;
    constructor Create(atable: TChanceTable; abits: Integer);
    function ReadInt(vmin, vmax: Integer): Integer;
    function ReadInt2(vmin, vmax: Integer): Integer;
  end;

constructor TSimpleCoder.Create(atable: TChanceTable; abits: Integer);
begin
  inherited Create;
  table := atable; nbits := abits;
  InitSymbolChance(s, nbits);
end;

threadvar
  { the decisions' source while a replay runs (one a thread) }
  tBits: TFlifBits;

function TSimpleCoder.ReadInt(vmin, vmax: Integer): Integer;
begin
  Result := ReadSymbol(tBits, s, table, nbits, vmin, vmax);
end;

function TSimpleCoder.ReadInt2(vmin, vmax: Integer): Integer;
begin
  if vmin > 0 then Result := ReadInt(0, vmax - vmin) + vmin
  else if vmax < 0 then Result := ReadInt(vmin - vmax, 0) + vmax
  else Result := ReadInt(vmin, vmax);
end;

{ UniformSymbolCoder.read_int(min, len): min .. min + len, halving }
function ReadUniform(vmin, vlen: Integer): Integer;
var med: Integer;
begin
  if vlen < 0 then raise EFlif.Create('flif: damaged stream');
  tBits.kind := FD_UNIFORM; tBits.idx := 0;
  while vlen > 0 do begin
    med := vlen div 2;
    if tBits.Uniform then begin
      vmin := vmin + med + 1;
      vlen := vlen - (med + 1);
    end else
      vlen := med;
  end;
  Result := vmin;
end;

{ ---------------- colour ranges ---------------- }

type
  TProps = array of Integer;     { properties, also "prevPlanes": the planes before }

  TRanges = class
    function NumPlanes: Integer; virtual; abstract;
    function Min(p: Integer): Integer; virtual; abstract;
    function Max(p: Integer): Integer; virtual; abstract;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); virtual;
    procedure Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); virtual;
    function IsStatic: Boolean; virtual;
  end;

procedure TRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  mi := Min(p); ma := Max(p);
end;

procedure TRanges.Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer);
begin
  MinMax(p, pp, mi, ma);
  if mi > ma then ma := mi;
  if v > ma then v := ma;
  if v < mi then v := mi;
end;

function TRanges.IsStatic: Boolean;
begin
  Result := True;
end;

type
  TStaticRanges = class(TRanges)
    lo, hi: array of Integer;
    constructor Create(n: Integer);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
  end;

constructor TStaticRanges.Create(n: Integer);
begin
  inherited Create;
  SetLength(lo, n); SetLength(hi, n);
end;

function TStaticRanges.NumPlanes: Integer; begin Result := Length(lo); end;
function TStaticRanges.Min(p: Integer): Integer; begin if p >= Length(lo) then Result := 0 else Result := lo[p]; end;
function TStaticRanges.Max(p: Integer): Integer; begin if p >= Length(hi) then Result := 0 else Result := hi[p]; end;

type
  TDupRanges = class(TRanges)
    prev: TRanges;
    constructor Create(aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    procedure Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TDupRanges.Create(aprev: TRanges); begin inherited Create; prev := aprev; end;
function TDupRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TDupRanges.Min(p: Integer): Integer; begin Result := prev.Min(p); end;
function TDupRanges.Max(p: Integer): Integer; begin Result := prev.Max(p); end;
procedure TDupRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); begin prev.MinMax(p, pp, mi, ma); end;
procedure TDupRanges.Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); begin prev.Snap(p, pp, mi, ma, v); end;
function TDupRanges.IsStatic: Boolean; begin Result := prev.IsStatic; end;

{ YCoCg: the ranges of Co given Y, and of Cg given Y and Co }
function MinCo(par, y: Integer): Integer;
begin
  if y < par - 1 then Result := -3 - 4 * y
  else if y >= 3 * par then Result := 4 * (1 + y - 4 * par)
  else Result := -4 * par + 1;
end;

function MaxCo(par, y: Integer): Integer;
begin
  if y < par - 1 then Result := 3 + 4 * y
  else if y >= 3 * par then Result := 4 * par - 4 * (1 + y - 3 * par)
  else Result := 4 * par - 1;
end;

function MinCg(par, y, co: Integer): Integer;
begin
  if (co < MinCo(par, y)) or (co > MaxCo(par, y)) then Exit(8 * par);
  if y < par - 1 then Result := -(2 * y + 1)
  else if y >= 3 * par then Result := -(2 * (4 * par - 1 - y) - ((1 + Abs(co)) div 2) * 2)
  else Result := -Math.Min(2 * par - 1 + (y - par + 1) * 2, 2 * par + (3 * par - 1 - y) * 2 - ((1 + Abs(co)) div 2) * 2);
end;

function MaxCg(par, y, co: Integer): Integer;
begin
  if (co < MinCo(par, y)) or (co > MaxCo(par, y)) then Exit(-8 * par);
  if y < par - 1 then Result := 1 + 2 * y - (Abs(co) div 2) * 2
  else if y >= 3 * par then Result := 2 * (4 * par - 1 - y)
  else Result := -Math.Max(-4 * par + (1 + y - 2 * par) * 2, -2 * par - (y - par) * 2 - 1 + (Abs(co) div 2) * 2);
end;

type
  TYCoCgRanges = class(TRanges)
    par: Integer;
    prev: TRanges;
    constructor Create(apar: Integer; aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TYCoCgRanges.Create(apar: Integer; aprev: TRanges); begin inherited Create; par := apar; prev := aprev; end;
function TYCoCgRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TYCoCgRanges.IsStatic: Boolean; begin Result := False; end;

function TYCoCgRanges.Min(p: Integer): Integer;
begin
  case p of
    0: Result := 0;
    1, 2: Result := -4 * par + 1;
  else Result := prev.Min(p);
  end;
end;

function TYCoCgRanges.Max(p: Integer): Integer;
begin
  case p of
    0, 1, 2: Result := 4 * par - 1;
  else Result := prev.Max(p);
  end;
end;

procedure TYCoCgRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  if p = 1 then begin mi := MinCo(par, pp[0]); ma := MaxCo(par, pp[0]); end
  else if p = 2 then begin mi := MinCg(par, pp[0], pp[1]); ma := MaxCg(par, pp[0], pp[1]); end
  else if p = 0 then begin mi := 0; ma := par * 4 - 1; end
  else prev.MinMax(p, pp, mi, ma);
end;

type
  TBoundsRanges = class(TRanges)
    lo, hi: array of Integer;
    prev: TRanges;
    constructor Create(aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    procedure Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TBoundsRanges.Create(aprev: TRanges); begin inherited Create; prev := aprev; end;
function TBoundsRanges.NumPlanes: Integer; begin Result := Length(lo); end;
function TBoundsRanges.IsStatic: Boolean; begin Result := False; end;
function TBoundsRanges.Min(p: Integer): Integer; begin Result := Math.Max(prev.Min(p), lo[p]); end;
function TBoundsRanges.Max(p: Integer): Integer; begin Result := Math.Min(prev.Max(p), hi[p]); end;

procedure TBoundsRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  if (p = 0) or (p = 3) then begin mi := lo[p]; ma := hi[p]; Exit; end;
  prev.MinMax(p, pp, mi, ma);
  if mi < lo[p] then mi := lo[p];
  if ma > hi[p] then ma := hi[p];
  if mi > ma then begin mi := lo[p]; ma := hi[p]; end;
end;

procedure TBoundsRanges.Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer);
begin
  if (p = 0) or (p = 3) then begin mi := lo[p]; ma := hi[p]; end
  else begin
    prev.Snap(p, pp, mi, ma, v);
    if mi < lo[p] then mi := lo[p];
    if ma > hi[p] then ma := hi[p];
    if mi > ma then begin mi := lo[p]; ma := hi[p]; end;
  end;
  if v > ma then v := ma;
  if v < mi then v := mi;
end;

type
  TPermuteRanges = class(TRanges)
    perm: array of Integer;
    subtract: Boolean;
    prev: TRanges;
    constructor Create(aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TPermuteRanges.Create(aprev: TRanges); begin inherited Create; prev := aprev; end;
function TPermuteRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TPermuteRanges.IsStatic: Boolean; begin Result := False; end;

function TPermuteRanges.Min(p: Integer): Integer;
begin
  if (not subtract) or (p = 0) or (p > 2) then Result := prev.Min(perm[p])
  else Result := prev.Min(perm[p]) - prev.Max(perm[0]);
end;

function TPermuteRanges.Max(p: Integer): Integer;
begin
  if (not subtract) or (p = 0) or (p > 2) then Result := prev.Max(perm[p])
  else Result := prev.Max(perm[p]) - prev.Min(perm[0]);
end;

procedure TPermuteRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  if (not subtract) or (p = 0) or (p > 2) then begin mi := Min(p); ma := Max(p); end
  else begin mi := prev.Min(perm[p]) - pp[0]; ma := prev.Max(perm[p]) - pp[0]; end;
end;

type
  { Palette (alpha = False) and Palette_Alpha (alpha = True) }
  TPaletteRanges = class(TRanges)
    nb: Integer;
    alpha: Boolean;
    prev: TRanges;
    constructor Create(aprev: TRanges; anb: Integer; aalpha: Boolean);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TPaletteRanges.Create(aprev: TRanges; anb: Integer; aalpha: Boolean);
begin inherited Create; prev := aprev; nb := anb; alpha := aalpha; end;
function TPaletteRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TPaletteRanges.IsStatic: Boolean; begin Result := False; end;

function TPaletteRanges.Min(p: Integer): Integer;
begin
  if p < 3 then Result := 0
  else if alpha and (p = 3) then Result := 1
  else Result := prev.Min(p);
end;

function TPaletteRanges.Max(p: Integer): Integer;
begin
  case p of
    0, 2: Result := 0;
    1: Result := nb - 1;
    3: if alpha then Result := 1 else Result := prev.Max(p);
  else Result := prev.Max(p);
  end;
end;

procedure TPaletteRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  if p = 1 then begin mi := 0; ma := nb - 1; end
  else if p < 3 then begin mi := 0; ma := 0; end
  else if alpha and (p = 3) then begin mi := 1; ma := 1; end
  else prev.MinMax(p, pp, mi, ma);
end;

type
  { Channel_Compact: each plane's values renumbered 0..nb }
  TCompactRanges = class(TRanges)
    nb: array[0..3] of Integer;
    prev: TRanges;
    constructor Create(aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
  end;

constructor TCompactRanges.Create(aprev: TRanges); begin inherited Create; prev := aprev; FillChar(nb, SizeOf(nb), 0); end;
function TCompactRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TCompactRanges.Min(p: Integer): Integer; begin Result := 0; end;
function TCompactRanges.Max(p: Integer): Integer; begin if p < 4 then Result := nb[p] else Result := 0; end;

type
  { Frame_Lookback: a fifth plane, how many frames back a pixel is taken from }
  TFCRanges = class(TRanges)
    numPrev, amin, amax: Integer;
    prev: TRanges;
    constructor Create(apf, aamin, aamax: Integer; aprev: TRanges);
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    procedure Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TFCRanges.Create(apf, aamin, aamax: Integer; aprev: TRanges);
begin inherited Create; numPrev := apf; amin := aamin; amax := aamax; prev := aprev; end;
function TFCRanges.NumPlanes: Integer; begin Result := 5; end;
function TFCRanges.IsStatic: Boolean; begin Result := False; end;

function TFCRanges.Min(p: Integer): Integer;
begin
  if p < 3 then Result := prev.Min(p) else if p = 3 then Result := amin else Result := 0;
end;

function TFCRanges.Max(p: Integer): Integer;
begin
  if p < 3 then Result := prev.Max(p) else if p = 3 then Result := amax else Result := numPrev;
end;

procedure TFCRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
begin
  if p >= 3 then begin mi := Min(p); ma := Max(p); end
  else prev.MinMax(p, pp, mi, ma);
end;

procedure TFCRanges.Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer);
begin
  if p >= 3 then inherited Snap(p, pp, mi, ma, v)
  else prev.Snap(p, pp, mi, ma, v);
end;

{ ---------------- colour buckets ---------------- }

const
  MAX_PER_BUCKET: array[0..3] of Integer = (255, 510, 5, 255);
  CB0A = 1; CB0B = 1; CB1 = 4;

type
  TBucket = record
    snapvalues: array of SmallInt;
    values: array of SmallInt;
    bmin, bmax: Integer;
    discrete: Boolean;
  end;
  PBucket = ^TBucket;

procedure BucketInit(var b: TBucket);
begin
  b.snapvalues := nil; b.values := nil;
  b.bmin := 10000; b.bmax := -10000; b.discrete := True;
end;

function BucketEmpty(const b: TBucket): Boolean;
begin
  Result := b.bmin > b.bmax;
end;

function SnapSlow(const b: TBucket; c: Integer): Integer;
var mindiff, diff, i, best: Integer;
begin
  if c <= b.bmin then Exit(b.bmin);
  if c >= b.bmax then Exit(b.bmax);
  if b.discrete then begin
    mindiff := Abs(c - b.bmin);
    best := 0;
    for i := 1 to High(b.values) do begin
      if c = b.values[i] then Exit(c);
      diff := Abs(c - b.values[i]);
      if diff < mindiff then begin best := i; mindiff := diff; end;
      if b.values[i] > c then Break;
    end;
    Exit(b.values[best]);
  end;
  Result := c;
end;

procedure PrepareSnap(var b: TBucket);
var c: Integer;
begin
  if b.discrete then begin
    b.snapvalues := nil;
    if b.bmax > b.bmin then SetLength(b.snapvalues, b.bmax - b.bmin);
    for c := b.bmin to b.bmax - 1 do b.snapvalues[c - b.bmin] := SnapSlow(b, c);
  end;
end;

function SnapColor(const b: TBucket; c: Integer): Integer;
begin
  if c <= b.bmin then Exit(b.bmin);
  if c >= b.bmax then Exit(b.bmax);
  if b.discrete then Exit(b.snapvalues[c - b.bmin]);
  Result := c;
end;

{ removeColor; False on a bucket that cannot lose it }
function RemoveColor(var b: TBucket; c: Integer): Boolean;
var pos, x, n: Integer;
begin
  if b.discrete then begin
    for pos := 0 to High(b.values) do
      if c = b.values[pos] then begin
        Delete(b.values, pos, 1);
        Break;
      end;
    if Length(b.values) = 0 then begin
      b.bmin := 10000; b.bmax := -10000;
      Exit(True);
    end;
    if c = b.bmin then b.bmin := b.values[0];
    if c = b.bmax then b.bmax := b.values[High(b.values)];
  end else begin
    if c = b.bmin then Inc(b.bmin);
    if c = b.bmax then Dec(b.bmax);
    if c > b.bmax then Exit(True);
    if c < b.bmin then Exit(True);
    b.discrete := True;
    b.values := nil;
    n := 0;
    SetLength(b.values, b.bmax - b.bmin + 1);
    for x := b.bmin to b.bmax do
      if x <> c then begin b.values[n] := x; Inc(n); end;
    SetLength(b.values, n);
  end;
  Result := True;
end;

type
  TBuckets = class
    bucket0, bucket3, emptyB: TBucket;
    min0, min1: Integer;
    bucket1: array of TBucket;
    bucket2: array of array of TBucket;
    ranges: TRanges;
    constructor Create(r: TRanges);
    function Find(p: Integer; const pp: TProps): PBucket;      { inside the tables }
    function FindC(p: Integer; const pp: TProps): PBucket;     { the empty bucket outside }
    function Exists(p: Integer; const pp: TProps): Boolean;
    function ExistsRange(p: Integer; const lower, upper: TProps): Boolean;
  end;

constructor TBuckets.Create(r: TRanges);
var i, j, n1, n2: Integer;
begin
  inherited Create;
  ranges := r;
  min0 := r.Min(0); min1 := r.Min(1);
  BucketInit(bucket0); BucketInit(bucket3); BucketInit(emptyB);
  n1 := (r.Max(0) - min0) div CB0A + 1;
  SetLength(bucket1, n1);
  for i := 0 to n1 - 1 do BucketInit(bucket1[i]);
  n1 := (r.Max(0) - min0) div CB0B + 1;
  n2 := (r.Max(1) - min1) div CB1 + 1;
  SetLength(bucket2, n1);
  for i := 0 to n1 - 1 do begin
    SetLength(bucket2[i], n2);
    for j := 0 to n2 - 1 do BucketInit(bucket2[i][j]);
  end;
end;

function TBuckets.Find(p: Integer; const pp: TProps): PBucket;
var i, j: Integer;
begin
  case p of
    0: Result := @bucket0;
    1: begin
         i := (pp[0] - min0) div CB0A;
         if (i < 0) or (i > High(bucket1)) then raise EFlif.Create('flif: damaged stream');
         Result := @bucket1[i];
       end;
    2: begin
         i := (pp[0] - min0) div CB0B; j := (pp[1] - min1) div CB1;
         if (i < 0) or (i > High(bucket2)) or (j < 0) or (j > High(bucket2[i])) then
           raise EFlif.Create('flif: damaged stream');
         Result := @bucket2[i][j];
       end;
  else Result := @bucket3;
  end;
end;

{ C++ integer division truncates toward zero, as Pascal's div does }
function TBuckets.FindC(p: Integer; const pp: TProps): PBucket;
var i, j: Integer;
begin
  case p of
    0: Result := @bucket0;
    1: begin
         i := (pp[0] - min0) div CB0A;
         if (i >= 0) and (i <= High(bucket1)) then Result := @bucket1[i] else Result := @emptyB;
       end;
    2: begin
         i := (pp[0] - min0) div CB0B; j := (pp[1] - min1) div CB1;
         if (i >= 0) and (i <= High(bucket2)) and (j >= 0) and (j <= High(bucket2[i])) then
           Result := @bucket2[i][j]
         else Result := @emptyB;
       end;
  else Result := @bucket3;
  end;
end;

function TBuckets.Exists(p: Integer; const pp: TProps): Boolean;
var rmin, rmax, v: Integer;
begin
  if (p > 0) and ((pp[0] < min0) or (pp[0] > ranges.Max(0))) then Exit(False);
  if (p > 1) and ((pp[1] < min1) or (pp[1] > ranges.Max(1))) then Exit(False);
  v := pp[p];
  ranges.Snap(p, pp, rmin, rmax, v);
  if v <> pp[p] then Exit(False);
  Result := SnapSlow(FindC(p, pp)^, pp[p]) = pp[p];
end;

function TBuckets.ExistsRange(p: Integer; const lower, upper: TProps): Boolean;
var pixel: TProps; a, b: Integer;
begin
  pixel := Copy(lower, 0, Length(lower));
  if Length(pixel) < 3 then SetLength(pixel, 3);
  if p = 0 then
    for a := lower[0] to upper[0] do begin
      pixel[0] := a;
      if Exists(p, pixel) then Exit(True);
    end;
  if p = 1 then
    for a := lower[0] to upper[0] do begin
      pixel[0] := a;
      for b := lower[1] to upper[1] do begin
        pixel[1] := b;
        if Exists(p, pixel) then Exit(True);
      end;
    end;
  Result := False;
end;

type
  TCBRanges = class(TRanges)
    prev: TRanges;
    cb: TBuckets;
    constructor Create(aprev: TRanges; acb: TBuckets);
    destructor Destroy; override;
    function NumPlanes: Integer; override;
    function Min(p: Integer): Integer; override;
    function Max(p: Integer): Integer; override;
    procedure MinMax(p: Integer; const pp: TProps; out mi, ma: Integer); override;
    procedure Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer); override;
    function IsStatic: Boolean; override;
  end;

constructor TCBRanges.Create(aprev: TRanges; acb: TBuckets); begin inherited Create; prev := aprev; cb := acb; end;
destructor TCBRanges.Destroy; begin cb.Free; inherited Destroy; end;
function TCBRanges.NumPlanes: Integer; begin Result := prev.NumPlanes; end;
function TCBRanges.IsStatic: Boolean; begin Result := False; end;
function TCBRanges.Min(p: Integer): Integer; begin Result := prev.Min(p); end;
function TCBRanges.Max(p: Integer): Integer; begin Result := prev.Max(p); end;

procedure TCBRanges.Snap(p: Integer; const pp: TProps; out mi, ma: Integer; var v: Integer);
var b: PBucket;
begin
  b := cb.FindC(p, pp);
  mi := b^.bmin; ma := b^.bmax;
  if b^.bmin > b^.bmax then begin mi := Min(p); v := mi; ma := Max(p); Exit; end;
  v := SnapColor(b^, v);
end;

procedure TCBRanges.MinMax(p: Integer; const pp: TProps; out mi, ma: Integer);
var b: PBucket;
begin
  b := cb.FindC(p, pp);
  mi := b^.bmin; ma := b^.bmax;
  if b^.bmin > b^.bmax then begin mi := Min(p); ma := Max(p); end;
end;

{ ---------------- the frames ---------------- }

type
  TFrame = record
    data: array[0..4] of array of Integer;   { a plane's pixels, rows of width }
    isConst: array[0..4] of Boolean;
    constVal: array[0..4] of Integer;
    colBegin, colEnd: array of Integer;      { Frame_Shape: the changed columns of each row }
    seenBefore: Integer;                     { Duplicate_Frame: the frame it repeats, or -1 }
  end;

  { MANIAC trees }
  TNode = record
    prop: Integer;        { -1: a leaf }
    count: Integer;
    splitval: Integer;
    child: Integer;
    leaf: Integer;
  end;
  TTree = array of TNode;

  { FinalPropertySymbolCoder: a tree, and the chances of its leaves }
  TPropCoder = class
    tree: ^TTree;
    leaves: array of TSymbolChance;
    nleaves: Integer;
    table: TChanceTable;
    nbits: Integer;
    constructor Create(var atree: TTree; atable: TChanceTable; abits: Integer);
    function FindLeaf(const props: TProps): Integer;
    function ReadInt(const props: TProps; vmin, vmax: Integer): Integer;
  end;

constructor TPropCoder.Create(var atree: TTree; atable: TChanceTable; abits: Integer);
begin
  inherited Create;
  tree := @atree;
  table := atable; nbits := abits;
  SetLength(leaves, 16);
  InitSymbolChance(leaves[0], nbits);
  nleaves := 1;
  if Length(atree) = 0 then raise EFlif.Create('flif: damaged stream');
  atree[0].leaf := 0;
end;

function TPropCoder.FindLeaf(const props: TProps): Integer;
var pos, oldLeaf, newLeaf: Integer;
begin
  pos := 0;
  while tree^[pos].prop <> -1 do begin
    if tree^[pos].count < 0 then begin
      if props[tree^[pos].prop] > tree^[pos].splitval then pos := tree^[pos].child
      else pos := tree^[pos].child + 1;
    end else if tree^[pos].count > 0 then begin
      Dec(tree^[pos].count);
      Break;
    end else begin
      Dec(tree^[pos].count);
      oldLeaf := tree^[pos].leaf;
      newLeaf := nleaves;
      if nleaves >= Length(leaves) then SetLength(leaves, nleaves * 2);
      leaves[newLeaf] := leaves[oldLeaf];
      Inc(nleaves);
      tree^[tree^[pos].child].leaf := oldLeaf;
      tree^[tree^[pos].child + 1].leaf := newLeaf;
      if props[tree^[pos].prop] > tree^[pos].splitval then Exit(oldLeaf)
      else Exit(newLeaf);
    end;
  end;
  Result := tree^[pos].leaf;
end;

function TPropCoder.ReadInt(const props: TProps; vmin, vmax: Integer): Integer;
var l: Integer;
begin
  if vmin = vmax then Exit(vmin);
  l := FindLeaf(props);
  Result := ReadSymbol(tBits, leaves[l], table, nbits, vmin, vmax);
end;

{ ---------------- the replay ---------------- }

const
  NB_PROPERTIES: array[0..4] of Integer = (8, 10, 9, 8, 8);
  NB_PROPERTIESA: array[0..4] of Integer = (9, 11, 10, 8, 8);
  NB_PROPERTIES_SL: array[0..4] of Integer = (7, 8, 9, 7, 7);
  NB_PROPERTIES_SLA: array[0..4] of Integer = (8, 9, 10, 7, 7);
  PLANE_ORDERING: array[0..4] of Integer = (4, 3, 0, 1, 2);
  MAX_PREDICTOR = 2;
  MAX_PALETTE_SIZE = 30000;
  { the decoder's limits: FLIF's own (MAX_IMAGE_BUFFER_SIZE, MAX_FRAMES) }
  MAX_BUFFER = Int64(5000) * 1000000;
  MAX_FRAMES = 50000;

type
  TPair = record lo, hi: Integer; end;
  TPairs = array of TPair;

  TReplay = class
    hd: TFlifHeader;
    W, H, nump: Integer;
    fr: array of TFrame;
    alphaZeroHeader: Boolean;
    alphaZero: Boolean;          { images[0].alpha_zero_special }
    palette: Boolean;
    cutoff: Integer;
    alpha: Int64;
    owned: array of TObject;     { ranges and tables, freed at the end }
    ranges: TRanges;
    metaTable, pixelTable: TChanceTable;
    forest: array of TTree;
    bits: Integer;               { 10 or 18 }
    invisiblePredictor: Integer;
    pixelsTodo, pixelsDone: Int64;
    { how a plane stores a value, as FLIF's planes do: 1 uint8, 2 uint16,
      3 int16, 0 int32 (an invisible pixel's prediction can leave the range) }
    store: array[0..4] of Integer;
    procedure Own(o: TObject);
    function Wrap(p, v: Integer): Integer; inline;
    function Zooms: Integer;
    function RowsZ(z: Integer): Integer;
    function ColsZ(z: Integer): Integer;
    function G(f, p, z, r, c: Integer): Integer; inline;
    procedure S(f, p, z, r, c, v: Integer); inline;
    function G0(f, p, r, c: Integer): Integer; inline;
    procedure S0(f, p, r, c, v: Integer); inline;
    procedure MakeConstant(f, p, v: Integer);
    procedure UndoConstant(f, p: Integer);
    procedure EnsureLookbacks;
    procedure Header;
    procedure Transforms;
    procedure ReadTree(p: Integer; const pr: TPairs);
    procedure InitPropRanges(p: Integer; out pr: TPairs);
    procedure InitPropRangesSL(p: Integer; out pr: TPairs);
    function PredictProps(f, p, z, r, c, predictor: Integer; horizontal: Boolean;
                          var props: TProps; out mi, ma: Integer): Integer;
    function InvisibleH(f, p, z, r, c, predictor: Integer): Integer;
    function InvisibleV(f, p, z, r, c, predictor: Integer): Integer;
    procedure RowH(cd: TPropCoder; var props: TProps; p, z, f, r, predictor: Integer);
    procedure RowV(cd: TPropCoder; var props: TProps; p, z, f, r, predictor: Integer);
    function Pass(beginZL, endZL: Integer): Boolean;
    function PredictPropsSL(f, p, r, c: Integer; var props: TProps; out mi, ma: Integer; fallback: Integer): Integer;
    function PredictSL(f, p, r, c, grey: Integer): Integer;
    procedure RowSL(cd: TPropCoder; var props: TProps; p, f, r, grey, minP: Integer);
    procedure Scanlines;
    procedure Run;
    destructor Destroy; override;
  end;

procedure TReplay.Own(o: TObject);
begin
  SetLength(owned, Length(owned) + 1);
  owned[High(owned)] := o;
end;

destructor TReplay.Destroy;
var i: Integer;
begin
  for i := High(owned) downto 0 do owned[i].Free;
  inherited Destroy;
end;

function RowPS(z: Integer): Integer; inline; begin Result := 1 shl ((z + 1) div 2); end;
function ColPS(z: Integer): Integer; inline; begin Result := 1 shl (z div 2); end;

function TReplay.Zooms: Integer;
begin
  Result := 0;
  while (RowPS(Result) < H) or (ColPS(Result) < W) do Inc(Result);
end;

function TReplay.RowsZ(z: Integer): Integer; begin Result := 1 + (H - 1) div RowPS(z); end;
function TReplay.ColsZ(z: Integer): Integer; begin Result := 1 + (W - 1) div ColPS(z); end;

function TReplay.G(f, p, z, r, c: Integer): Integer; inline;
begin
  if fr[f].isConst[p] then Result := fr[f].constVal[p]
  else Result := fr[f].data[p][SizeInt(r) * RowPS(z) * W + SizeInt(c) * ColPS(z)];
end;

function TReplay.Wrap(p, v: Integer): Integer; inline;
begin
  case store[p] of
    1: Result := v and $FF;
    2: Result := v and $FFFF;
    3: Result := SmallInt(v and $FFFF);
  else Result := v;
  end;
end;

procedure TReplay.S(f, p, z, r, c, v: Integer); inline;
begin
  if not fr[f].isConst[p] then fr[f].data[p][SizeInt(r) * RowPS(z) * W + SizeInt(c) * ColPS(z)] := Wrap(p, v);
end;

function TReplay.G0(f, p, r, c: Integer): Integer; inline;
begin
  if fr[f].isConst[p] then Result := fr[f].constVal[p]
  else Result := fr[f].data[p][SizeInt(r) * W + c];
end;

procedure TReplay.S0(f, p, r, c, v: Integer); inline;
begin
  if not fr[f].isConst[p] then fr[f].data[p][SizeInt(r) * W + c] := Wrap(p, v);
end;

procedure TReplay.MakeConstant(f, p, v: Integer);
begin
  if (p > 3) or (p < 0) then Exit;
  fr[f].data[p] := nil;
  fr[f].isConst[p] := True;
  fr[f].constVal[p] := v;
end;

procedure TReplay.UndoConstant(f, p: Integer);
var i: SizeInt; v: Integer;
begin
  if not fr[f].isConst[p] then Exit;
  v := fr[f].constVal[p];
  fr[f].isConst[p] := False;
  SetLength(fr[f].data[p], SizeInt(W) * H);
  for i := 0 to High(fr[f].data[p]) do fr[f].data[p][i] := v;
end;

{ Frame_Lookback's fifth plane (ensure_frame_lookbacks: chroma 0 and alpha
  1 if the image had none) }
procedure TReplay.EnsureLookbacks;
var f: Integer;
begin
  if nump >= 5 then Exit;
  for f := 0 to High(fr) do begin
    if nump < 2 then MakeConstant(f, 1, 0);
    if nump < 3 then MakeConstant(f, 2, 0);
    if nump < 4 then MakeConstant(f, 3, 1);
    fr[f].isConst[4] := False;
    SetLength(fr[f].data[4], SizeInt(W) * H);
  end;
  nump := 5;
end;

{ the header fields in the range-coded stream, before the transforms }
procedure TReplay.Header;
var p, maxv, maxmax, f: Integer; st: TStaticRanges;
begin
  maxmax := 0;
  st := TStaticRanges.Create(hd.numPlanes);
  Own(st);
  for p := 0 to hd.numPlanes - 1 do begin
    maxv := 255;
    if hd.depthChar = Ord('2') then maxv := 65535
    else if hd.depthChar = Ord('0') then maxv := (1 shl ReadUniform(1, 15)) - 1;
    if maxv > maxmax then maxmax := maxv;
  end;
  { semi_init: the image's maximum, rounded up to all ones }
  if (maxmax and (maxmax + 1)) <> 0 then begin
    maxmax := maxmax or (maxmax shr 1); maxmax := maxmax or (maxmax shr 2);
    maxmax := maxmax or (maxmax shr 4); maxmax := maxmax or (maxmax shr 8);
  end;
  if maxmax >= 65536 then raise EFlif.Create('flif: unsupported depth');
  { the planes' types (Image::real_init): Y and A uint8, chroma int16 for
    8 bits; uint16 and int32 above; the lookbacks uint8 }
  if maxmax < 256 then begin store[0] := 1; store[1] := 3; store[2] := 3; store[3] := 1; end
  else begin store[0] := 2; store[1] := 0; store[2] := 0; store[3] := 2; end;
  store[4] := 1;
  for p := 0 to hd.numPlanes - 1 do begin st.lo[p] := 0; st.hi[p] := maxmax; end;
  ranges := st;
  alphaZeroHeader := False;
  if hd.numPlanes > 3 then alphaZeroHeader := ReadUniform(0, 1) <> 0;
  if hd.numFrames > 1 then ReadUniform(0, 100);
  { the planes in memory (32 bits a value, up to five planes a frame):
    within 512 MB, or the file stays as bytes }
  if Int64(W) * H * hd.numFrames * 5 > Int64(1) shl 27 then raise EFlif.Create('flif: too large');
  SetLength(fr, hd.numFrames);
  for f := 0 to High(fr) do begin
    FillChar(fr[f].isConst, SizeOf(fr[f].isConst), 0);
    FillChar(fr[f].constVal, SizeOf(fr[f].constVal), 0);
    for p := 0 to 4 do fr[f].data[p] := nil;
    for p := 0 to hd.numPlanes - 1 do SetLength(fr[f].data[p], SizeInt(W) * H);
    SetLength(fr[f].colBegin, H); SetLength(fr[f].colEnd, H);
    for p := 0 to H - 1 do begin fr[f].colBegin[p] := 0; fr[f].colEnd[p] := W; end;
    fr[f].seenBefore := -1;
    if hd.numFrames > 1 then ReadUniform(0, 60000);
  end;
  nump := hd.numPlanes;
  alphaZero := alphaZeroHeader;
  palette := False;
  cutoff := 2;
  alpha := Int64($FFFFFFFF) div 19;
  if ReadUniform(0, 1) <> 0 then begin
    cutoff := ReadUniform(1, 127);
    alpha := Int64($FFFFFFFF) div ReadUniform(2, 126);
    if ReadUniform(0, 1) <> 0 then raise EFlif.Create('flif: non-default chances');
  end;
end;

function Median3(a, b, c: Integer): Integer; inline;
begin
  if a < b then begin
    if b < c then Result := b
    else if a < c then Result := c else Result := a;
  end else begin
    if a < c then Result := a
    else if b < c then Result := c else Result := b;
  end;
end;

function Sar1(x: Integer): Integer; inline;
begin
  Result := SarLongint(x, 1);
end;

function TBuckets_MinMax(src: TRanges; p: Integer; const lower, upper: TProps; out smin, smax: Integer): Boolean;
var pixel: TProps; rmin, rmax, a, b: Integer;
begin
  smin := 10000; smax := -10000;
  pixel := Copy(lower, 0, Length(lower));
  if Length(pixel) < 3 then SetLength(pixel, 3);
  case p of
    0, 3: src.MinMax(p, pixel, smin, smax);
    1: for a := lower[0] to upper[0] do begin
         pixel[0] := a;
         src.MinMax(1, pixel, rmin, rmax);
         if rmin < smin then smin := rmin;
         if rmax > smax then smax := rmax;
       end;
    2: for a := lower[0] to upper[0] do begin
         pixel[0] := a;
         for b := lower[1] to upper[1] do begin
           pixel[1] := b;
           src.MinMax(2, pixel, rmin, rmax);
           if rmin < smin then smin := rmin;
           if rmax > smax then smax := rmax;
         end;
       end;
  end;
  Result := True;
end;

procedure TReplay.Transforms;
var tnb, tpnb, p, i, j, k, nb, vmin, remaining, size, sorted, f, unique, cols, mlb, lookback,
    A, Y, I0, Q, prevA, prevY, prevI: Integer;
    src: TRanges; c, cY, cI, cQ, cA: TSimpleCoder; cbc: array[0..5] of TSimpleCoder;
    pp, L, U: TProps; bmin, bmax: array[0..3] of Integer;
    cr: TCompactRanges; st: TStaticRanges; br: TBoundsRanges; pr: TPermuteRanges;
    cb: TBuckets; seen, bb, ee: array of Integer; from, toP: array[0..4] of Boolean;
    aZeroSpecial: Boolean; minc, maxc: array[0..3] of Integer; next: TRanges;

  function NewCoder: TSimpleCoder;
  begin
    Result := TSimpleCoder.Create(metaTable, 18);
    Own(Result);
  end;

  function LoadBucket(plane: Integer; const lo, up: TProps): TBucket;
  var smin, smax, n, q, v, pl: Integer;
  begin
    Result := Default(TBucket);
    BucketInit(Result);
    if plane < 3 then
      for pl := 0 to plane - 1 do
        if not cb.ExistsRange(pl, lo, up) then Exit;
    TBuckets_MinMax(src, plane, lo, up, smin, smax);
    if cbc[0].ReadInt2(0, 1) = 0 then Exit;
    if smin = smax then begin Result.bmin := smin; Result.bmax := smin; Result.discrete := False; Exit; end;
    Result.bmin := cbc[1].ReadInt2(smin, smax);
    Result.bmax := cbc[2].ReadInt2(Result.bmin, smax);
    if Result.bmin = Result.bmax then begin Result.discrete := False; Exit; end;
    if Result.bmin + 1 = Result.bmax then begin Result.discrete := False; Exit; end;
    Result.discrete := cbc[3].ReadInt2(0, 1) <> 0;
    if Result.discrete then begin
      n := cbc[4].ReadInt2(2, Math.Min(MAX_PER_BUCKET[plane], Result.bmax - Result.bmin));
      SetLength(Result.values, 1);
      Result.values[0] := Result.bmin;
      v := Result.bmin;
      for q := 1 to n - 2 do begin
        SetLength(Result.values, Length(Result.values) + 1);
        Result.values[q] := cbc[5].ReadInt2(v + 1, Result.bmax + 1 - n + q);
        v := Result.values[q];
      end;
      if Result.bmin < Result.bmax then begin
        SetLength(Result.values, Length(Result.values) + 1);
        Result.values[High(Result.values)] := Result.bmax;
      end;
    end;
  end;

begin
  tpnb := -1;
  st := nil; br := nil; aZeroSpecial := False;
  SetLength(pp, 3);
  tBits.part := FP_HEADER; tBits.plane := 0; tBits.zoom := 0;
  while True do begin
    tBits.kind := FD_UNIFORM; tBits.idx := 0;
    if not tBits.Uniform then Break;
    tnb := ReadUniform(0, 13);
    if tnb <= tpnb then raise EFlif.Create('flif: transforms out of order');
    tpnb := tnb;
    src := ranges;
    next := nil;
    case tnb of
      0: begin   { Channel_Compact }
           if src.NumPlanes > 4 then raise EFlif.Create('flif: damaged stream');
           c := NewCoder;
           cr := TCompactRanges.Create(src); Own(cr);
           for p := 0 to src.NumPlanes - 1 do begin
             nb := c.ReadInt(0, src.Max(p) - src.Min(p)) + 1;
             vmin := src.Min(p);
             remaining := nb - 1;
             for i := 0 to nb - 1 do begin
               vmin := vmin + c.ReadInt(0, src.Max(p) - vmin - remaining) + 1;
               Dec(remaining);
             end;
             if p < 4 then cr.nb[p] := nb - 1;
           end;
           next := cr;
         end;
      1: begin   { YCoCg }
           if src.NumPlanes < 3 then raise EFlif.Create('flif: damaged stream');
           if (src.Min(0) < 0) or (src.Min(1) < 0) or (src.Min(2) < 0) then raise EFlif.Create('flif: damaged stream');
           if (src.Min(0) = src.Max(0)) or (src.Min(1) = src.Max(1)) or (src.Min(2) = src.Max(2)) then
             raise EFlif.Create('flif: damaged stream');
           next := TYCoCgRanges.Create(Math.Max(Math.Max(src.Max(0), src.Max(1)), src.Max(2)) div 4 + 1, src);
           Own(next);
         end;
      3: begin   { PermutePlanes }
           if src.NumPlanes < 3 then raise EFlif.Create('flif: damaged stream');
           if (src.Min(0) < 0) or (src.Min(1) < 0) or (src.Min(2) < 0) then raise EFlif.Create('flif: damaged stream');
           pr := TPermuteRanges.Create(src); Own(pr);
           SetLength(pr.perm, src.NumPlanes);
           c := NewCoder;
           pr.subtract := c.ReadInt2(0, 1) <> 0;
           FillChar(from, SizeOf(from), 0); FillChar(toP, SizeOf(toP), 0);
           for p := 0 to src.NumPlanes - 1 do begin
             pr.perm[p] := c.ReadInt2(0, src.NumPlanes - 1);
             from[p] := True;
             toP[pr.perm[p]] := True;
           end;
           for p := 0 to src.NumPlanes - 1 do
             if not from[p] or not toP[p] then raise EFlif.Create('flif: damaged stream');
           next := pr;
         end;
      4: begin   { Bounds }
           if src.NumPlanes > 4 then raise EFlif.Create('flif: damaged stream');
           c := NewCoder;
           if src.IsStatic then begin st := TStaticRanges.Create(src.NumPlanes); Own(st); end
           else begin br := TBoundsRanges.Create(src); Own(br); SetLength(br.lo, src.NumPlanes); SetLength(br.hi, src.NumPlanes); end;
           for p := 0 to src.NumPlanes - 1 do begin
             vmin := c.ReadInt2(src.Min(p), src.Max(p));
             nb := c.ReadInt2(vmin, src.Max(p));
             if (vmin > nb) or (vmin < src.Min(p)) or (nb > src.Max(p)) then raise EFlif.Create('flif: damaged stream');
             if src.IsStatic then begin st.lo[p] := vmin; st.hi[p] := nb; end
             else begin br.lo[p] := vmin; br.hi[p] := nb; end;
           end;
           if src.IsStatic then next := st else next := br;
         end;
      5, 6: begin   { Palette_Alpha, Palette }
           if tnb = 5 then begin
             aZeroSpecial := alphaZero;
             if src.NumPlanes < 4 then raise EFlif.Create('flif: damaged stream');
             if src.Min(3) = src.Max(3) then raise EFlif.Create('flif: damaged stream');
           end else begin
             if src.NumPlanes < 3 then raise EFlif.Create('flif: damaged stream');
             if (src.Max(0) = 0) and (src.Max(2) = 0) and (src.NumPlanes > 3) and (src.Min(3) = 1) and (src.Max(3) = 1) then
               raise EFlif.Create('flif: damaged stream');
             if (src.Min(1) = src.Max(1)) and (src.Min(2) = src.Max(2)) then raise EFlif.Create('flif: damaged stream');
           end;
           c := NewCoder; cY := NewCoder; cI := NewCoder; cQ := NewCoder;
           if tnb = 5 then cA := NewCoder else cA := nil;
           size := c.ReadInt2(1, MAX_PALETTE_SIZE);
           sorted := c.ReadInt2(0, 1);
           pp[0] := 0; pp[1] := 0;
           if tnb = 5 then begin
             if sorted <> 0 then begin
               minc[0] := src.Min(3); minc[1] := src.Min(0); minc[2] := src.Min(1); minc[3] := src.Min(2);
               maxc[0] := src.Max(3); maxc[1] := src.Max(0); maxc[2] := src.Max(1); maxc[3] := src.Max(2);
               prevA := -1; prevY := -1;
               for k := 1 to size do begin
                 A := cA.ReadInt2(minc[0], maxc[0]);
                 if aZeroSpecial and (A = 0) then Continue;
                 if prevA = A then Y := cY.ReadInt2(prevY, maxc[1]) else Y := cY.ReadInt2(minc[1], maxc[1]);
                 pp[0] := Y; src.MinMax(1, pp, minc[2], maxc[2]);
                 I0 := cI.ReadInt2(minc[2], maxc[2]);
                 pp[1] := I0; src.MinMax(2, pp, minc[3], maxc[3]);
                 cQ.ReadInt2(minc[3], maxc[3]);
                 minc[0] := A;
                 prevA := A; prevY := Y;
               end;
             end else
               for k := 1 to size do begin
                 A := cA.ReadInt2(src.Min(3), src.Max(3));
                 if aZeroSpecial and (A = 0) then Continue;
                 src.MinMax(0, pp, vmin, nb); Y := cY.ReadInt2(vmin, nb);
                 pp[0] := Y; src.MinMax(1, pp, vmin, nb); I0 := cI.ReadInt2(vmin, nb);
                 pp[1] := I0; src.MinMax(2, pp, vmin, nb); cQ.ReadInt2(vmin, nb);
               end;
             palette := True;
             alphaZero := False;
             next := TPaletteRanges.Create(src, size, True); Own(next);
           end else begin
             if sorted <> 0 then begin
               minc[0] := src.Min(0); minc[1] := src.Min(1); minc[2] := src.Min(2);
               maxc[0] := src.Max(0); maxc[1] := src.Max(1); maxc[2] := src.Max(2);
               prevY := -1; prevI := -1;
               for k := 1 to size do begin
                 Y := cY.ReadInt2(minc[0], maxc[0]);
                 pp[0] := Y; src.MinMax(1, pp, minc[1], maxc[1]);
                 if prevY = Y then I0 := cI.ReadInt2(prevI, maxc[1]) else I0 := cI.ReadInt2(minc[1], maxc[1]);
                 pp[1] := I0; src.MinMax(2, pp, minc[2], maxc[2]);
                 cQ.ReadInt2(minc[2], maxc[2]);
                 minc[0] := Y;
                 prevY := Y; prevI := I0;
               end;
             end else
               for k := 1 to size do begin
                 src.MinMax(0, pp, vmin, nb); Y := cY.ReadInt2(vmin, nb);
                 pp[0] := Y; src.MinMax(1, pp, vmin, nb); I0 := cI.ReadInt2(vmin, nb);
                 pp[1] := I0; src.MinMax(2, pp, vmin, nb); cQ.ReadInt2(vmin, nb);
               end;
             palette := True;
             next := TPaletteRanges.Create(src, size, False); Own(next);
           end;
         end;
      7: begin   { Color_Buckets }
           if src.NumPlanes < 3 then raise EFlif.Create('flif: damaged stream');
           if (src.Min(1) = src.Max(1)) and (src.Min(2) = src.Max(2)) then raise EFlif.Create('flif: damaged stream');
           if (src.Min(0) = 0) and (src.Max(0) = 0) and (src.Min(2) = 0) and (src.Max(2) = 0) then raise EFlif.Create('flif: damaged stream');
           if (src.Min(0) = src.Max(0)) and (src.Min(1) = src.Max(1)) and (src.Min(2) = src.Max(2)) then raise EFlif.Create('flif: damaged stream');
           if (src.Max(0) - src.Min(0) > 1023) or (src.Max(1) - src.Min(1) > 1023) or (src.Max(2) - src.Min(2) > 1023) then
             raise EFlif.Create('flif: damaged stream');
           if src.Min(1) = src.Max(1) then raise EFlif.Create('flif: damaged stream');
           cb := TBuckets.Create(src);
           next := TCBRanges.Create(src, cb); Own(next);
           for k := 0 to 5 do cbc[k] := NewCoder;
           L := nil; U := nil;
           cb.bucket0 := LoadBucket(0, L, U);
           SetLength(L, 1); SetLength(U, 1);
           L[0] := cb.min0; U[0] := cb.min0 + CB0A - 1;
           for k := 0 to High(cb.bucket1) do begin
             cb.bucket1[k] := LoadBucket(1, L, U);
             L[0] := L[0] + CB0A; U[0] := U[0] + CB0A;
           end;
           if src.Min(2) < src.Max(2) then begin
             L[0] := cb.min0; U[0] := cb.min0 + CB0B - 1;
             SetLength(L, 2); SetLength(U, 2);
             L[1] := cb.min1; U[1] := cb.min1 + CB1 - 1;
             for k := 0 to High(cb.bucket2) do begin
               L[1] := cb.min1; U[1] := cb.min1 + CB1 - 1;
               for j := 0 to High(cb.bucket2[k]) do begin
                 cb.bucket2[k][j] := LoadBucket(2, L, U);
                 L[1] := L[1] + CB1; U[1] := U[1] + CB1;
               end;
               L[0] := L[0] + CB0B; U[0] := U[0] + CB0B;
             end;
           end;
           if src.NumPlanes > 3 then cb.bucket3 := LoadBucket(3, L, U);
           { meta: a Cg bucket that is empty removes its Co values }
           if src.Min(2) < src.Max(2) then begin
             SetLength(L, 3); SetLength(U, 3);
             L[0] := cb.min0; U[0] := cb.min0 + CB0B - 1;
             L[1] := cb.min1; U[1] := cb.min1 + CB1 - 1;
             for k := 0 to High(cb.bucket2) do begin
               L[1] := cb.min1; U[1] := cb.min1 + CB1 - 1;
               for j := 0 to High(cb.bucket2[k]) do begin
                 if BucketEmpty(cb.bucket2[k][j]) then
                   for i := L[1] to U[1] do begin
                     RemoveColor(cb.Find(1, L)^, i);
                     RemoveColor(cb.Find(1, U)^, i);
                   end;
                 L[1] := L[1] + CB1; U[1] := U[1] + CB1;
               end;
               L[0] := L[0] + CB0B; U[0] := U[0] + CB0B;
             end;
           end;
           PrepareSnap(cb.bucket0);
           PrepareSnap(cb.bucket3);
           for k := 0 to High(cb.bucket1) do PrepareSnap(cb.bucket1[k]);
           for k := 0 to High(cb.bucket2) do
             for j := 0 to High(cb.bucket2[k]) do PrepareSnap(cb.bucket2[k][j]);
         end;
      10: begin   { Duplicate_Frame }
           if Length(fr) < 2 then raise EFlif.Create('flif: damaged stream');
           c := NewCoder;
           SetLength(seen, Length(fr));
           seen[0] := -1;
           for k := 1 to High(fr) do seen[k] := c.ReadInt(-1, k - 1);
           for k := 0 to High(fr) do fr[k].seenBefore := seen[k];
           next := TDupRanges.Create(src); Own(next);
         end;
      11: begin   { Frame_Shape }
           if Length(fr) < 2 then raise EFlif.Create('flif: damaged stream');
           unique := Length(fr) - 1;
           for k := 0 to High(fr) do if fr[k].seenBefore >= 0 then Dec(unique);
           if unique < 1 then raise EFlif.Create('flif: damaged stream');
           nb := unique * H;
           cols := W;
           c := NewCoder;
           SetLength(bb, nb); SetLength(ee, nb);
           for k := 0 to nb - 1 do bb[k] := c.ReadInt(0, cols);
           for k := 0 to nb - 1 do begin
             ee[k] := cols - c.ReadInt(0, cols - bb[k]);
             if (ee[k] > cols) or (ee[k] < bb[k]) or (ee[k] <= 0) then raise EFlif.Create('flif: damaged stream');
           end;
           k := 0;
           for f := 1 to High(fr) do begin
             if fr[f].seenBefore >= 0 then Continue;
             for i := 0 to H - 1 do begin
               fr[f].colBegin[i] := bb[k];
               fr[f].colEnd[i] := ee[k];
               Inc(k);
             end;
           end;
           next := TDupRanges.Create(src); Own(next);
         end;
      12: begin   { Frame_Lookback }
           if Length(fr) < 2 then raise EFlif.Create('flif: damaged stream');
           if src.NumPlanes > 4 then raise EFlif.Create('flif: damaged stream');
           c := NewCoder;
           mlb := c.ReadInt2(1, Length(fr) - 1);
           EnsureLookbacks;
           lookback := Length(fr) - 1;
           if lookback > mlb then lookback := mlb;
           if src.NumPlanes = 4 then next := TFCRanges.Create(lookback, src.Min(3), src.Max(3), src)
           else next := TFCRanges.Create(lookback, 1, 1, src);
           Own(next);
         end;
    else
      raise EFlif.Create('flif: unknown transform');
    end;
    ranges := next;
  end;
end;

procedure TReplay.InitPropRanges(p: Integer; out pr: TPairs);
var n, q, mi, ma, mind, maxd: Integer;
  procedure Add(a, b: Integer); begin SetLength(pr, n + 1); pr[n].lo := a; pr[n].hi := b; Inc(n); end;
begin
  pr := nil; n := 0;
  mi := ranges.Min(p); ma := ranges.Max(p); mind := mi - ma; maxd := ma - mi;
  if p < 3 then begin
    for q := 0 to p - 1 do Add(ranges.Min(q), ranges.Max(q));
    if ranges.NumPlanes > 3 then Add(ranges.Min(3), ranges.Max(3));
  end;
  Add(0, 2);
  if (p = 1) or (p = 2) then Add(ranges.Min(0) - ranges.Max(0), ranges.Max(0) - ranges.Min(0));
  for q := 1 to 4 do Add(mind, maxd);
  Add(mi, ma);
  if p <> 2 then begin Add(mind, maxd); Add(mind, maxd); end;
end;

procedure TReplay.InitPropRangesSL(p: Integer; out pr: TPairs);
var n, q, mi, ma, mind, maxd: Integer;
  procedure Add(a, b: Integer); begin SetLength(pr, n + 1); pr[n].lo := a; pr[n].hi := b; Inc(n); end;
begin
  pr := nil; n := 0;
  mi := ranges.Min(p); ma := ranges.Max(p); mind := mi - ma; maxd := ma - mi;
  if p < 3 then begin
    for q := 0 to p - 1 do Add(ranges.Min(q), ranges.Max(q));
    if ranges.NumPlanes > 3 then Add(ranges.Min(3), ranges.Max(3));
  end;
  Add(mi, ma);
  Add(0, 2);
  for q := 1 to 5 do Add(mind, maxd);
end;

{ MetaPropertySymbolCoder.read_tree, with a stack instead of recursion }
procedure TReplay.ReadTree(p: Integer; const pr: TPairs);
type TFrameRec = record pos, stage, prop, oldmin, oldmax, split, child: Integer; end;
var c0, c1, c2: TSimpleCoder; sub: TPairs; stack: array of TFrameRec; sp, n, q: Integer;
    t: ^TTree;
begin
  c0 := TSimpleCoder.Create(metaTable, 18); Own(c0);
  c1 := TSimpleCoder.Create(metaTable, 18); Own(c1);
  c2 := TSimpleCoder.Create(metaTable, 18); Own(c2);
  sub := Copy(pr, 0, Length(pr));
  t := @forest[p];
  SetLength(t^, 1);
  t^[0].prop := -1; t^[0].count := 0; t^[0].splitval := 0; t^[0].child := 0; t^[0].leaf := 0;
  n := 1;
  SetLength(stack, 64);
  sp := 0;
  stack[0].pos := 0; stack[0].stage := 0;
  tBits.part := FP_TREE; tBits.plane := p; tBits.zoom := 0;
  while sp >= 0 do begin
    case stack[sp].stage of
      0: begin
           q := c0.ReadInt2(0, Length(pr)) - 1;
           t^[stack[sp].pos].prop := q;
           if q = -1 then begin Dec(sp); Continue; end;
           if (q < 0) or (q >= Length(pr)) then raise EFlif.Create('flif: damaged tree');
           stack[sp].prop := q;
           stack[sp].oldmin := sub[q].lo; stack[sp].oldmax := sub[q].hi;
           if stack[sp].oldmin >= stack[sp].oldmax then raise EFlif.Create('flif: damaged tree');
           t^[stack[sp].pos].count := c1.ReadInt2(1, 512);
           stack[sp].split := c2.ReadInt2(stack[sp].oldmin, stack[sp].oldmax - 1);
           t^[stack[sp].pos].splitval := stack[sp].split;
           if n > 1 shl 24 then raise EFlif.Create('flif: tree too large');
           stack[sp].child := n;
           t^[stack[sp].pos].child := n;
           SetLength(t^, n + 2);
           t^[n].prop := -1; t^[n].count := 0; t^[n].splitval := 0; t^[n].child := 0; t^[n].leaf := 0;
           t^[n + 1] := t^[n];
           n := n + 2;
           sub[q].lo := stack[sp].split + 1;
           stack[sp].stage := 1;
           if sp + 1 >= Length(stack) then SetLength(stack, Length(stack) * 2);
           Inc(sp);
           stack[sp].pos := stack[sp - 1].child; stack[sp].stage := 0;
         end;
      1: begin
           q := stack[sp].prop;
           sub[q].lo := stack[sp].oldmin;
           sub[q].hi := stack[sp].split;
           stack[sp].stage := 2;
           if sp + 1 >= Length(stack) then SetLength(stack, Length(stack) * 2);
           Inc(sp);
           stack[sp].pos := stack[sp - 1].child + 1; stack[sp].stage := 0;
         end;
    else
      sub[stack[sp].prop].hi := stack[sp].oldmax;
      Dec(sp);
    end;
  end;
end;

{ predict_and_calcProps_plane: the guess, its range, and the properties }
function TReplay.PredictProps(f, p, z, r, c, predictor: Integer; horizontal: Boolean;
                              var props: TProps; out mi, ma: Integer): Integer;
var i, rows, cols, left, top, topleft, topright, bottomleft, bottom, right, bottomright,
    avg, tlg, median, which, guess: Integer; bottomPresent, rightPresent: Boolean;
begin
  i := 0;
  if p < 3 then begin
    if p > 0 then begin props[i] := G(f, 0, z, r, c); Inc(i); end;
    if p > 1 then begin props[i] := G(f, 1, z, r, c); Inc(i); end;
    if nump > 3 then begin props[i] := G(f, 3, z, r, c); Inc(i); end;
  end;
  rows := RowsZ(z); cols := ColsZ(z);
  bottomPresent := r + 1 < rows;
  rightPresent := c + 1 < cols;
  if horizontal then begin
    top := G(f, p, z, r - 1, c);
    if c > 0 then left := G(f, p, z, r, c - 1) else left := top;
    if c > 0 then topleft := G(f, p, z, r - 1, c - 1) else topleft := top;
    if rightPresent then topright := G(f, p, z, r - 1, c + 1) else topright := top;
    if bottomPresent and (c > 0) then bottomleft := G(f, p, z, r + 1, c - 1) else bottomleft := left;
    if bottomPresent then bottom := G(f, p, z, r + 1, c) else bottom := left;
    avg := Sar1(top + bottom);
    tlg := left + top - topleft;
    median := Median3(avg, tlg, left + bottom - bottomleft);
    which := 2;
    if median = avg then which := 0 else if median = tlg then which := 1;
    props[i] := which; Inc(i);
    if (p = 1) or (p = 2) then begin
      if bottomPresent then props[i] := G(f, 0, z, r, c) - Sar1(G(f, 0, z, r - 1, c) + G(f, 0, z, r + 1, c))
      else props[i] := G(f, 0, z, r, c) - Sar1(G(f, 0, z, r - 1, c) + G(f, 0, z, r - 1, c));
      Inc(i);
    end;
    if predictor = 0 then guess := avg
    else if predictor = 1 then guess := median
    else guess := Median3(top, bottom, left);
    ranges.Snap(p, props, mi, ma, guess);
    props[i] := top - bottom; Inc(i);
    props[i] := top - Sar1(topleft + topright); Inc(i);
    props[i] := left - Sar1(bottomleft + topleft); Inc(i);
    if rightPresent and bottomPresent then bottomright := G(f, p, z, r + 1, c + 1) else bottomright := bottom;
    props[i] := bottom - Sar1(bottomleft + bottomright); Inc(i);
  end else begin
    left := G(f, p, z, r, c - 1);
    if r > 0 then top := G(f, p, z, r - 1, c) else top := left;
    if r > 0 then topleft := G(f, p, z, r - 1, c - 1) else topleft := left;
    if (r > 0) and rightPresent then topright := G(f, p, z, r - 1, c + 1) else topright := top;
    if bottomPresent then bottomleft := G(f, p, z, r + 1, c - 1) else bottomleft := left;
    if rightPresent then right := G(f, p, z, r, c + 1) else right := top;
    avg := Sar1(left + right);
    tlg := left + top - topleft;
    median := Median3(avg, tlg, right + top - topright);
    which := 2;
    if median = avg then which := 0 else if median = tlg then which := 1;
    props[i] := which; Inc(i);
    if (p = 1) or (p = 2) then begin
      if rightPresent then props[i] := G(f, 0, z, r, c) - Sar1(G(f, 0, z, r, c - 1) + G(f, 0, z, r, c + 1))
      else props[i] := G(f, 0, z, r, c) - Sar1(G(f, 0, z, r, c - 1) + G(f, 0, z, r, c - 1));
      Inc(i);
    end;
    if predictor = 0 then guess := avg
    else if predictor = 1 then guess := median
    else guess := Median3(top, left, right);
    ranges.Snap(p, props, mi, ma, guess);
    props[i] := left - right; Inc(i);
    props[i] := left - Sar1(bottomleft + topleft); Inc(i);
    props[i] := top - Sar1(topleft + topright); Inc(i);
    if rightPresent and bottomPresent then bottomright := G(f, p, z, r + 1, c + 1) else bottomright := right;
    props[i] := right - Sar1(bottomright + topright); Inc(i);
  end;
  props[i] := guess; Inc(i);
  if p <> 2 then begin
    if r > 1 then props[i] := G(f, p, z, r - 2, c) - top else props[i] := 0;
    Inc(i);
    if c > 1 then props[i] := G(f, p, z, r, c - 2) - left else props[i] := 0;
    Inc(i);
  end;
  Result := guess;
end;

{ predict_plane_horizontal / vertical: the value of an invisible pixel }
function TReplay.InvisibleH(f, p, z, r, c, predictor: Integer): Integer;
var top, bottom, left, topleft, bottomleft, rows: Integer;
begin
  if p = 4 then Exit(0);
  rows := RowsZ(z);
  top := G(f, p, z, r - 1, c);
  if r + 1 < rows then bottom := G(f, p, z, r + 1, c) else bottom := top;
  if predictor = 0 then Exit(Sar1(top + bottom));
  if c > 0 then left := G(f, p, z, r, c - 1) else left := top;
  if predictor = 1 then begin
    if c > 0 then topleft := G(f, p, z, r - 1, c - 1) else topleft := top;
    if (c > 0) and (r + 1 < rows) then bottomleft := G(f, p, z, r + 1, c - 1) else bottomleft := left;
    Exit(Median3(Sar1(top + bottom), left + top - topleft, left + bottom - bottomleft));
  end;
  Result := Median3(top, bottom, left);
end;

function TReplay.InvisibleV(f, p, z, r, c, predictor: Integer): Integer;
var left, right, top, topleft, topright, cols: Integer;
begin
  if p = 4 then Exit(0);
  cols := ColsZ(z);
  left := G(f, p, z, r, c - 1);
  if c + 1 < cols then right := G(f, p, z, r, c + 1) else right := left;
  if predictor = 0 then Exit(Sar1(left + right));
  if r > 0 then top := G(f, p, z, r - 1, c) else top := left;
  if predictor = 1 then begin
    if r > 0 then topleft := G(f, p, z, r - 1, c - 1) else topleft := left;
    if (r > 0) and (c + 1 < cols) then topright := G(f, p, z, r - 1, c + 1) else topright := top;
    Exit(Median3(Sar1(left + right), left + top - topleft, right + top - topright));
  end;
  Result := Median3(top, left, right);
end;

{ one row of plane p at zoom level z (even: horizontal lines), frame f }
procedure TReplay.RowH(cd: TPropCoder; var props: TProps; p, z, f, r, predictor: Integer);
var cols, beginC, endC, c, rp, mi, ma, guess, fra, v: Integer; isFRA: Boolean;
  function AlphaZeroAt(cc: Integer): Boolean;
  begin
    if (nump > 3) and not fr[f].isConst[3] then Result := G(f, 3, z, r, cc) = 0
    else Result := G(f, 0, z, r, cc) = 0;
  end;
begin
  cols := ColsZ(z);
  beginC := 0; endC := cols;
  isFRA := nump = 5;
  if fr[f].seenBefore >= 0 then begin
    for c := 0 to cols - 1 do S(f, p, z, r, c, G(fr[f].seenBefore, p, z, r, c));
    Exit;
  end;
  if f > 0 then begin
    rp := r * RowPS(z);
    beginC := fr[f].colBegin[rp] div ColPS(z);
    endC := 1 + (fr[f].colEnd[rp] - 1) div ColPS(z);
    if alphaZero and (p < 3) then begin
      for c := 0 to beginC - 1 do
        if AlphaZeroAt(c) then S(f, p, z, r, c, InvisibleH(f, p, z, r, c, invisiblePredictor))
        else S(f, p, z, r, c, G(f - 1, p, z, r, c));
    end else if p <> 4 then begin
      for c := 0 to beginC - 1 do S(f, p, z, r, c, G(f - 1, p, z, r, c));
      for c := endC to cols - 1 do S(f, p, z, r, c, G(f - 1, p, z, r, c));
    end;
  end;
  tBits.plane := p; tBits.zoom := z;
  for c := beginC to endC - 1 do begin
    if alphaZero and (p < 3) and AlphaZeroAt(c) then begin
      S(f, p, z, r, c, InvisibleH(f, p, z, r, c, invisiblePredictor));
      Continue;
    end;
    if isFRA and (p < 4) then begin
      fra := G(f, 4, z, r, c);
      if fra > 0 then begin
        if fra > f then raise EFlif.Create('flif: damaged stream');
        S(f, p, z, r, c, G(f - fra, p, z, r, c));
        Continue;
      end;
    end;
    guess := PredictProps(f, p, z, r, c, predictor, True, props, mi, ma);
    if isFRA and (p = 4) and (ma > f) then ma := f;
    if isFRA and ((guess > ma) or (guess < mi)) then guess := mi;
    tBits.guess := guess;
    v := cd.ReadInt(props, mi - guess, ma - guess) + guess;
    S(f, p, z, r, c, v);
  end;
  if (f > 0) and alphaZero and (p < 3) then
    for c := endC to cols - 1 do
      if AlphaZeroAt(c) then S(f, p, z, r, c, InvisibleH(f, p, z, r, c, invisiblePredictor))
      else S(f, p, z, r, c, G(f - 1, p, z, r, c));
end;

{ one row at an odd zoom level (vertical lines: the odd columns) }
procedure TReplay.RowV(cd: TPropCoder; var props: TProps; p, z, f, r, predictor: Integer);
var cols, beginC, endC, c, rp, mi, ma, guess, fra, v: Integer; isFRA: Boolean;
  function AlphaZeroAt(cc: Integer): Boolean;
  begin
    if (nump > 3) and not fr[f].isConst[3] then Result := G(f, 3, z, r, cc) = 0
    else Result := G(f, 0, z, r, cc) = 0;
  end;
begin
  cols := ColsZ(z);
  beginC := 1; endC := cols;
  isFRA := nump = 5;
  if fr[f].seenBefore >= 0 then begin
    c := 1;
    while c < cols do begin S(f, p, z, r, c, G(fr[f].seenBefore, p, z, r, c)); c := c + 2; end;
    Exit;
  end;
  if f > 0 then begin
    rp := r * RowPS(z);
    beginC := fr[f].colBegin[rp] div ColPS(z);
    endC := (1 + (fr[f].colEnd[rp] - 1) div ColPS(z)) or 1;
    if (beginC > 1) and not Odd(beginC) then Dec(beginC);
    if beginC = 0 then beginC := 1;
    if alphaZero and (p < 3) then begin
      c := 1;
      while c < beginC do begin
        if AlphaZeroAt(c) then S(f, p, z, r, c, InvisibleV(f, p, z, r, c, invisiblePredictor))
        else S(f, p, z, r, c, G(f - 1, p, z, r, c));
        c := c + 2;
      end;
    end else if p <> 4 then begin
      c := 1;
      while c < beginC do begin S(f, p, z, r, c, G(f - 1, p, z, r, c)); c := c + 2; end;
      c := endC;
      while c < cols do begin S(f, p, z, r, c, G(f - 1, p, z, r, c)); c := c + 2; end;
    end;
  end;
  tBits.plane := p; tBits.zoom := z;
  c := beginC;
  while c < endC do begin
    if alphaZero and (p < 3) and AlphaZeroAt(c) then
      S(f, p, z, r, c, InvisibleV(f, p, z, r, c, invisiblePredictor))
    else begin
      fra := 0;
      if isFRA and (p < 4) then fra := G(f, 4, z, r, c);
      if fra > 0 then begin
        if fra > f then raise EFlif.Create('flif: damaged stream');
        S(f, p, z, r, c, G(f - fra, p, z, r, c));
      end else begin
        guess := PredictProps(f, p, z, r, c, predictor, False, props, mi, ma);
        if isFRA and (p = 4) and (ma > f) then ma := f;
        if isFRA and ((guess > ma) or (guess < mi)) then guess := mi;
        tBits.guess := guess;
        v := cd.ReadInt(props, mi - guess, ma - guess) + guess;
        S(f, p, z, r, c, v);
      end;
    end;
    c := c + 2;
  end;
  if (f > 0) and alphaZero and (p < 3) then begin
    c := endC;
    while c < cols do begin
      if AlphaZeroAt(c) then S(f, p, z, r, c, InvisibleV(f, p, z, r, c, invisiblePredictor))
      else S(f, p, z, r, c, G(f - 1, p, z, r, c));
      c := c + 2;
    end;
  end;
end;

{ the interlaced pass from zoom level beginZL down to endZL }
function TReplay.Pass(beginZL, endZL: Integer): Boolean;
var coders: array of TPropCoder; p, f, i, n, z, r, predictor, np, nextp, q, hp: Integer;
    defaultOrder: Boolean; thePredictor, zoomlevels, czl: array of Integer;
    maxBehind: array[0..4] of Integer; props: TProps; pr: TPairs;
begin
  Result := False;
  SetLength(coders, nump);
  for p := 0 to nump - 1 do begin
    coders[p] := TPropCoder.Create(forest[p], pixelTable, bits);
    Own(coders[p]);
  end;
  tBits.part := FP_HEADER; tBits.plane := 0; tBits.zoom := 0;
  if (beginZL = Zooms) and (endZL > 0) then
    for p := 0 to nump - 1 do
      if ranges.Min(p) < ranges.Max(p) then begin
        for f := 0 to High(fr) do S(f, p, 0, 0, 0, ReadUniform(ranges.Min(p), ranges.Max(p) - ranges.Min(p)));
        Inc(pixelsDone);
      end;
  defaultOrder := ReadUniform(0, 1) <> 0;
  SetLength(thePredictor, nump);
  for p := 0 to nump - 1 do thePredictor[p] := ReadUniform(-1, MAX_PREDICTOR + 1);
  SetLength(zoomlevels, nump);
  for p := 0 to nump - 1 do zoomlevels[p] := beginZL;
  np := nump;
  n := np * (beginZL - endZL + 1);
  for i := 0 to n - 1 do begin
    tBits.part := FP_HEADER;
    if defaultOrder then begin
      { plane_zoomlevel: alpha and lookbacks first, chroma lagging behind luma }
      maxBehind[0] := 0; maxBehind[1] := 2; maxBehind[2] := 4; maxBehind[3] := 0; maxBehind[4] := 0;
      if ranges.Min(0) >= ranges.Max(0) then begin maxBehind[1] := 0; maxBehind[2] := 1; end;
      SetLength(czl, np);
      for q := 0 to np - 1 do czl[q] := beginZL + 1;
      hp := 0;
      if np >= 4 then hp := 3;
      if np >= 5 then hp := 4;
      nextp := hp;
      q := i;
      while q >= 0 do begin
        Dec(czl[nextp]);
        Dec(q);
        if q < 0 then Break;
        nextp := hp;
        for p := 0 to np - 1 do
          if czl[p] > czl[hp] + maxBehind[p] then nextp := p;
        while czl[nextp] <= endZL do nextp := (nextp + 1) mod np;
      end;
      p := nextp;
      if zoomlevels[p] <> czl[p] then raise EFlif.Create('flif: damaged stream');
    end else begin
      p := ReadUniform(0, np - 1);
      if (np > 3) and alphaZero and (p < 3) and (zoomlevels[p] <= zoomlevels[3]) then
        raise EFlif.Create('flif: damaged stream');
      if (np > 4) and (p < 4) and (zoomlevels[p] <= zoomlevels[4]) then
        raise EFlif.Create('flif: damaged stream');
    end;
    z := zoomlevels[p];
    if z < 0 then raise EFlif.Create('flif: damaged stream');
    if (100 * pixelsDone > 100 * pixelsTodo) and (endZL = 0) then Exit;   { quality reached: FLIF stops }
    if ranges.Min(p) < ranges.Max(p) then begin
      if thePredictor[p] < 0 then predictor := ReadUniform(0, MAX_PREDICTOR)
      else predictor := thePredictor[p];
      if nump > 3 then SetLength(props, NB_PROPERTIESA[p]) else SetLength(props, NB_PROPERTIES[p]);
      InitPropRanges(p, pr);
      if Length(pr) <> Length(props) then raise EFlif.Create('flif: damaged stream');
      tBits.part := FP_PIXEL;
      if not Odd(z) then begin
        r := 1;
        while r < RowsZ(z) do begin
          pixelsDone := pixelsDone + ColsZ(z);
          for f := 0 to High(fr) do RowH(coders[p], props, p, z, f, r, predictor);
          r := r + 2;
        end;
      end else
        for r := 0 to RowsZ(z) - 1 do begin
          pixelsDone := pixelsDone + ColsZ(z) div 2;
          for f := 0 to High(fr) do RowV(coders[p], props, p, z, f, r, predictor);
        end;
    end;
    Dec(zoomlevels[p]);
  end;
  Result := True;
end;

{ ---------------- scanlines (non-interlaced) ---------------- }

function TReplay.PredictSL(f, p, r, c, grey: Integer): Integer;
var left, top, topleft: Integer;
begin
  if c > 0 then left := G0(f, p, r, c - 1)
  else if r > 0 then left := G0(f, p, r - 1, c)
  else left := grey;
  if r > 0 then top := G0(f, p, r - 1, c) else top := left;
  if (r > 0) and (c > 0) then topleft := G0(f, p, r - 1, c - 1) else topleft := top;
  Result := Median3(left + top - topleft, left, top);
end;

function TReplay.PredictPropsSL(f, p, r, c: Integer; var props: TProps; out mi, ma: Integer; fallback: Integer): Integer;
var i, q, left, top, topleft, grad, guess, which: Integer;
begin
  i := 0;
  if p < 3 then begin
    for q := 0 to p - 1 do begin props[i] := G0(f, q, r, c); Inc(i); end;
    if nump > 3 then begin props[i] := G0(f, 3, r, c); Inc(i); end;
  end;
  if c > 0 then left := G0(f, p, r, c - 1)
  else if r > 0 then left := G0(f, p, r - 1, c)
  else left := fallback;
  if r > 0 then top := G0(f, p, r - 1, c) else top := left;
  if (r > 0) and (c > 0) then topleft := G0(f, p, r - 1, c - 1)
  else if r > 0 then topleft := top
  else topleft := left;
  grad := left + top - topleft;
  guess := Median3(grad, left, top);
  ranges.Snap(p, props, mi, ma, guess);
  which := 0;
  if guess = grad then which := 0
  else if guess = left then which := 1
  else if guess = top then which := 2;
  props[i] := guess; Inc(i);
  props[i] := which; Inc(i);
  if (c > 0) and (r > 0) then begin
    props[i] := left - topleft; Inc(i);
    props[i] := topleft - top; Inc(i);
  end else begin
    props[i] := 0; Inc(i); props[i] := 0; Inc(i);
  end;
  if (c + 1 < W) and (r > 0) then props[i] := top - G0(f, p, r - 1, c + 1) else props[i] := 0;
  Inc(i);
  if r > 1 then props[i] := G0(f, p, r - 2, c) - top else props[i] := 0;
  Inc(i);
  if c > 1 then props[i] := G0(f, p, r, c - 2) - left else props[i] := 0;
  Result := guess;
end;

procedure TReplay.RowSL(cd: TPropCoder; var props: TProps; p, f, r, grey, minP: Integer);
var beginC, endC, c, mi, ma, guess, fra, v: Integer; isFRA: Boolean;
  function AlphaAt(cc: Integer): Integer;
  begin
    if nump > 3 then Result := G0(f, 3, r, cc) else Result := 1;
  end;
begin
  beginC := 0; endC := W;
  isFRA := nump = 5;
  if fr[f].seenBefore >= 0 then begin
    for c := 0 to W - 1 do S0(f, p, r, c, G0(fr[f].seenBefore, p, r, c));
    Exit;
  end;
  if f > 0 then begin
    beginC := fr[f].colBegin[r]; endC := fr[f].colEnd[r];
    if alphaZero and (p < 3) then begin
      for c := 0 to beginC - 1 do
        if AlphaAt(c) = 0 then S0(f, p, r, c, PredictSL(f, p, r, c, grey))
        else S0(f, p, r, c, G0(f - 1, p, r, c));
    end else if p <> 4 then
      for c := 0 to beginC - 1 do S0(f, p, r, c, G0(f - 1, p, r, c));
  end;
  tBits.plane := p; tBits.zoom := 0;
  for c := beginC to endC - 1 do begin
    if alphaZero and (p < 3) and (AlphaAt(c) = 0) then begin
      S0(f, p, r, c, PredictSL(f, p, r, c, grey));
      Continue;
    end;
    if isFRA and (p < 4) then begin
      fra := G0(f, 4, r, c);
      if fra > 0 then begin
        if fra > f then raise EFlif.Create('flif: damaged stream');
        S0(f, p, r, c, G0(f - fra, p, r, c));
        Continue;
      end;
    end;
    guess := PredictPropsSL(f, p, r, c, props, mi, ma, minP);
    if isFRA and (p = 4) and (ma > f) then ma := f;
    tBits.guess := guess;
    v := cd.ReadInt(props, mi - guess, ma - guess) + guess;
    S0(f, p, r, c, v);
  end;
  if f > 0 then begin
    if alphaZero and (p < 3) then begin
      for c := endC to W - 1 do
        if AlphaAt(c) = 0 then S0(f, p, r, c, PredictSL(f, p, r, c, grey))
        else S0(f, p, r, c, G0(f - 1, p, r, c));
    end else if p <> 4 then
      for c := endC to W - 1 do S0(f, p, r, c, G0(f - 1, p, r, c));
  end;
end;

procedure TReplay.Scanlines;
var coders: array of TPropCoder; k, p, r, f: Integer; props: TProps;
begin
  SetLength(coders, nump);
  for p := 0 to nump - 1 do begin
    coders[p] := TPropCoder.Create(forest[p], pixelTable, bits);
    Own(coders[p]);
  end;
  tBits.part := FP_PIXEL;
  for k := 0 to 4 do begin
    p := PLANE_ORDERING[k];
    if p >= nump then Continue;
    if nump > 3 then SetLength(props, NB_PROPERTIES_SLA[p]) else SetLength(props, NB_PROPERTIES_SL[p]);
    if ranges.Min(p) < ranges.Max(p) then
      for r := 0 to H - 1 do
        for f := 0 to High(fr) do
          RowSL(coders[p], props, p, f, r, (ranges.Min(p) + ranges.Max(p)) div 2, ranges.Min(p));
  end;
end;

{ ---------------- the whole stream ---------------- }

procedure TReplay.Run;
var p, f, real, mbits, nb, roughZL: Integer; pr: TPairs; done: Boolean;
begin
  W := hd.width; H := hd.height;
  metaTable := TChanceTable.Create(2, Int64($FFFFFFFF) div 19); Own(metaTable);
  Header;
  Transforms;
  invisiblePredictor := 0;
  tBits.part := FP_HEADER;
  if alphaZeroHeader and (ranges.NumPlanes > 3) and (ranges.Min(3) <= 0) and hd.interlaced then
    invisiblePredictor := ReadUniform(0, MAX_PREDICTOR);
  if ranges.NumPlanes <> nump then raise EFlif.Create('flif: damaged stream');
  real := 0;
  for p := 0 to nump - 1 do if ranges.Min(p) < ranges.Max(p) then Inc(real);
  pixelsTodo := Int64(W) * H * real;
  pixelsDone := 0;
  if pixelsTodo = 0 then begin pixelsTodo := 1; pixelsDone := 1; end;
  for p := 0 to nump - 1 do
    if ranges.Min(p) >= ranges.Max(p) then
      for f := 0 to High(fr) do MakeConstant(f, p, ranges.Min(p));
  for f := 0 to High(fr) do begin
    UndoConstant(f, 0);
    for p := 0 to nump - 1 do
      if not fr[f].isConst[p] and (Length(fr[f].data[p]) = 0) then SetLength(fr[f].data[p], SizeInt(W) * H);
  end;
  if (nump > 3) and (ranges.Min(3) > 0) then alphaZero := False;
  if (nump > 3) and (ranges.Max(3) = 0) then alphaZero := False;
  mbits := 0;
  for p := 0 to nump - 1 do
    if ranges.Max(p) > ranges.Min(p) then begin
      nb := ILog2((Int64(ranges.Max(p)) - ranges.Min(p)) * 2 - 1) + 1;
      if nb > mbits then mbits := nb;
    end;
  bits := 10;
  if mbits > 10 then bits := 18;
  if mbits > bits then raise EFlif.Create('flif: more than 16 bits');
  pixelTable := TChanceTable.Create(cutoff, alpha); Own(pixelTable);
  SetLength(forest, nump);
  for p := 0 to nump - 1 do begin
    SetLength(forest[p], 1);
    forest[p][0].prop := -1; forest[p][0].count := 0; forest[p][0].splitval := 0;
    forest[p][0].child := 0; forest[p][0].leaf := 0;
  end;
  done := True;
  if hd.interlaced then begin
    tBits.part := FP_HEADER;
    roughZL := ReadUniform(0, Zooms);
    done := Pass(Zooms, roughZL + 1);
    if done then begin
      if not ((pixelsDone >= pixelsTodo) and (pixelsTodo > 1)) then begin
        for p := 0 to nump - 1 do
          if ranges.Min(p) < ranges.Max(p) then begin
            InitPropRanges(p, pr);
            ReadTree(p, pr);
          end;
        done := Pass(roughZL, 0);
      end;
    end;
  end else begin
    for p := 0 to nump - 1 do
      if ranges.Min(p) < ranges.Max(p) then begin
        InitPropRangesSL(p, pr);
        ReadTree(p, pr);
      end;
    Scanlines;
  end;
  { the checksum }
  tBits.part := FP_HEADER; tBits.plane := 0; tBits.zoom := 0;
  if ReadUniform(0, 1) <> 0 then begin
    ReadUniform(0, 65535);
    ReadUniform(0, 65535);
  end;
end;

function ReadVarint(const d: TBytes; var pos: SizeInt; out v: Int64): Boolean;
var k, b: Integer;
begin
  v := 0;
  for k := 1 to 10 do begin
    if pos >= Length(d) then Exit(False);
    b := d[pos]; Inc(pos);
    if b < 128 then begin v := v + b; Exit(v < (Int64(1) shl 31)); end;
    v := (v + (b - 128)) shl 7;
    if v > (Int64(1) shl 40) then Exit(False);
  end;
  Result := False;
end;

function ParseFlifHeader(const d: TBytes; out h: TFlifHeader): Boolean;
var pos: SizeInt; c: Integer; v: Int64; name0: Integer;
begin
  Result := False;
  h := Default(TFlifHeader);
  if (Length(d) < 8) or (d[0] <> Ord('F')) or (d[1] <> Ord('L')) or (d[2] <> Ord('I')) or (d[3] <> Ord('F')) then Exit;
  c := d[4];
  if (c < 32) or (c > 32 + 32 + 15 + 32) then Exit;
  c := c - 32;
  h.numFrames := 1;
  if c > 47 then begin c := c - 32; h.numFrames := 2; end;
  if c div 16 = 1 then h.interlaced := False
  else if c div 16 = 2 then h.interlaced := True
  else Exit;
  h.numPlanes := c mod 16;
  if (h.numPlanes < 1) or (h.numPlanes > 4) or (h.numPlanes = 2) then Exit;
  h.depthChar := d[5];
  if (h.depthChar < Ord('0')) or (h.depthChar > Ord('2')) then Exit;
  pos := 6;
  if not ReadVarint(d, pos, v) then Exit;
  h.width := v + 1;
  if not ReadVarint(d, pos, v) then Exit;
  h.height := v + 1;
  if (h.width < 1) or (h.height < 1) or (h.width > 1 shl 24) or (h.height > 1 shl 24) then Exit;
  if h.numFrames > 1 then begin
    if not ReadVarint(d, pos, v) then Exit;
    if v > MAX_FRAMES then Exit;
    h.numFrames := v + 2;
  end;
  { metadata chunks: a 4-letter name and a length; a zero byte ends them }
  while True do begin
    if pos >= Length(d) then Exit;
    name0 := d[pos];
    if name0 < 32 then begin
      if name0 <> 0 then Exit;     { a later FLIF version }
      Inc(pos);
      Break;
    end;
    if pos + 4 > Length(d) then Exit;
    if name0 <= Ord('Z') then begin
      { only iCCP, eXif and eXmp are known; another critical chunk stops a decoder }
      if not (((d[pos] = Ord('i')) and (d[pos + 1] = Ord('C')) and (d[pos + 2] = Ord('C')) and (d[pos + 3] = Ord('P'))) or
              ((d[pos] = Ord('e')) and (d[pos + 1] = Ord('X')) and (d[pos + 2] = Ord('i')) and (d[pos + 3] = Ord('f'))) or
              ((d[pos] = Ord('e')) and (d[pos + 1] = Ord('X')) and (d[pos + 2] = Ord('m')) and (d[pos + 3] = Ord('p')))) then Exit;
    end;
    pos := pos + 4;
    if not ReadVarint(d, pos, v) then Exit;
    if pos + v > Length(d) then Exit;
    pos := pos + v;
  end;
  h.racStart := pos;
  Result := True;
end;

procedure ReplayFlif(const h: TFlifHeader; bits: TFlifBits);
var rp: TReplay;
begin
  tBits := bits;
  rp := TReplay.Create;
  try
    rp.hd := h;
    rp.Run;
  finally
    rp.Free;
    tBits := nil;
  end;
end;

{ ---------------- PAIA's side ---------------- }

function FHash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

constructor TFlifModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(t) do t[i].Init(tableBits, 255);
  mx.Init(Length(t) + 2, 3 * 5 * 16, 1, 11);
  apm.Init(3 * 5 * 36 * 4, 7);
  hist := 0;
end;

function TFlifModel.Code(cd: TCoder; bit, b12: Integer; src: TFlifBits): Integer;
var k, q, pl, z, g, j, pm, pa, p: Integer; h: array[0..5] of QWord; idx: array[0..5] of SizeInt;
begin
  k := (src.part * 5 + src.kind) * 36 + src.idx;
  q := b12 shr 5;
  pl := src.plane; z := src.zoom;
  if src.part = FP_PIXEL then g := (src.guess + 4096) shr 3 else g := 0;
  h[0] := FHash(k, pl);
  h[1] := FHash(k * 128 + q, pl + 8);
  h[2] := FHash(k * 64 + Min(z, 63), pl + 16);
  h[3] := FHash(k * 256 + (hist and 255), pl + 24);
  h[4] := FHash(FHash(k * 128 + q, hist and 15), pl + 32);
  h[5] := FHash(FHash(k, g), pl * 64 + Min(z, 63) + 40);
  mx.Add(Stretch(b12));
  for j := 0 to High(t) do begin
    idx[j] := h[j] and t[j].mask;
    mx.Add(Stretch(t[j].P12(idx[j])));
  end;
  mx.Add(256);
  pm := mx.Mix((src.part * 5 + src.kind) * 16 + (b12 shr 8));
  pa := apm.Refine(pm, k * 4 + (b12 shr 10));
  p := (pm + 3 * pa) div 4;
  if p < 1 then p := 1 else if p > 4095 then p := 4095;
  Result := cd.Code(bit, p);
  for j := 0 to High(t) do t[j].Update(idx[j], Result);
  mx.Update(Result);
  apm.Update(Result);
  hist := (hist shl 1) or Result;
end;

type
  { compressing: FLIF's decisions as read, coded by the model; decompressing:
    the model's, written again with FLIF's range coder }
  TFlifCodeBits = class(TFlifBits)
    cd: TCoder;
    m: TFlifModel;
    rin: TFlifRacIn;
    rout: TFlifRacOut;
    function Decide(b12: Integer): Boolean; override;
    function Uniform: Boolean; override;
  end;

  { finding: only FLIF's own decoder and the inverse coder }
  TFlifCheckBits = class(TFlifBits)
    rin: TFlifRacIn;
    rout: TFlifRacOut;
    function Decide(b12: Integer): Boolean; override;
    function Uniform: Boolean; override;
  end;

function TFlifCodeBits.Decide(b12: Integer): Boolean;
var bit: Integer;
begin
  bit := 0;
  if cd.encoding then bit := Ord(rin.Get12(b12));
  Result := m.Code(cd, bit, b12, Self) <> 0;
  rout.Put12(Result, b12);
end;

function TFlifCodeBits.Uniform: Boolean;
var bit: Integer;
begin
  bit := 0;
  if cd.encoding then bit := Ord(rin.GetHalf);
  Result := m.Code(cd, bit, 2048, Self) <> 0;
  rout.PutHalf(Result);
end;

function TFlifCheckBits.Decide(b12: Integer): Boolean;
begin
  Result := rin.Get12(b12);
  rout.Put12(Result, b12);
end;

function TFlifCheckBits.Uniform: Boolean;
begin
  Result := rin.GetHalf;
  rout.PutHalf(Result);
end;

{ the stream's last bytes, those the inverse coder leaves pending (four in
  every file tried): a length, then the bytes, at even odds }
procedure CodeTail(cd: TCoder; var data: TBytes; at, len: SizeInt);
var i, b, bit, v, cnt: Integer;
begin
  cnt := 0;
  if cd.encoding then cnt := Integer(len - at);
  v := 0;
  for b := 15 downto 0 do begin
    bit := (cnt shr b) and 1;
    bit := cd.Code(bit, 2048);
    v := v * 2 + bit;
  end;
  if at + v <> len then raise EFlif.Create('flif: damaged stream');
  for i := 0 to v - 1 do begin
    cnt := 0;
    for b := 7 downto 0 do begin
      bit := (data[at + i] shr b) and 1;
      bit := cd.Code(bit, 2048);
      cnt := cnt * 2 + bit;
    end;
    data[at + i] := cnt;
  end;
end;

function FindFlifStream(const d: TBytes; out s: TFlifStream): Boolean;
var bits: TFlifCheckBits; i: SizeInt;
begin
  Result := False;
  s := Default(TFlifStream);
  if not ParseFlifHeader(d, s.hdr) then Exit;
  bits := TFlifCheckBits.Create;
  try
    bits.rin := TFlifRacIn.Create(d, s.hdr.racStart, Length(d));
    bits.rout := TFlifRacOut.Create;
    try
      ReplayFlif(s.hdr, bits);
    except
      on EFlif do Exit;
      on ERangeError do Exit;
      on EIntOverflow do Exit;
    end;
    { the bytes the coder gives back must be the stream's; the tail after
      them is kept as it is, and the stream ends with the file }
    if (bits.rout.outLen > Length(d) - s.hdr.racStart) or (Length(d) - s.hdr.racStart - bits.rout.outLen > 65535) then Exit;
    for i := 0 to bits.rout.outLen - 1 do
      if bits.rout.outBuf[i] <> d[s.hdr.racStart + i] then Exit;
    s.dataStart := s.hdr.racStart;
    s.dataEnd := Length(d);
    Result := True;
  finally
    bits.rin.Free; bits.rout.Free;
    bits.Free;
  end;
end;

procedure CodeFlifStream(cd: TCoder; m: TFlifModel; const h: TFlifHeader; var data: TBytes; len: SizeInt);
var bits: TFlifCodeBits; at: SizeInt;
begin
  bits := TFlifCodeBits.Create;
  try
    bits.cd := cd; bits.m := m;
    if cd.encoding then bits.rin := TFlifRacIn.Create(data, 0, len) else bits.rin := nil;
    bits.rout := TFlifRacOut.Create;
    ReplayFlif(h, bits);
    at := bits.rout.outLen;
    if at > len then raise EFlif.Create('flif: damaged stream');
    if not cd.encoding then begin
      data := nil;
      SetLength(data, len);
      if at > 0 then Move(bits.rout.outBuf[0], data[0], at);
    end;
    CodeTail(cd, data, at, len);
  finally
    bits.rin.Free; bits.rout.Free;
    bits.Free;
  end;
end;

end.
