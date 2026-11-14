{ IFF ANIM (Amiga): finding the frames' pixel data, and coding it.

  An ANIM is a FORM ANIM of FORM ILBMs: the first holds the first frame
  (BMHD, CMAP, BODY: bitplanes, row by row, plane by plane, usually
  ByteRun1-compressed), each other one a delta (ANHD, DLTA). Every delta
  method FFmpeg reads is taken: 5 (Byte Vertical Delta, by far the most
  used), 3, 7, 8 (short and long), 74 ("J"), 100, 101 and 108 (doc/CODEC.md).

  As for FLICs, the bytes of a BODY and of a DLTA are coded in their own
  order, field by field: structure to a token model, bitplane bytes to a
  model that sees the bitmaps as the frames build them (what the byte
  replaces, the frame before, the neighbours in its plane, the plane below
  at the same place). Exact by construction. The frames are double
  buffered, as players do: a delta changes the frame two back, unless its
  ANHD says one back.

  A BODY's mask plane (BMHD masking 1) is walked as one more plane. Not
  taken (they stay as plain bytes): BODYs of other compressions, chunky
  (deep) ILBMs. }
unit paiaiff;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiaiff: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiaiff: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, Math, paiaarith, paiadib;

const
  IK_BODY_RAW = 0;
  IK_BODY_RLE = 1;
  IK_DLTA5 = 2;      { Byte Vertical Delta }
  IK_DLTA3 = 3;      { short horizontal delta }
  IK_DLTA7 = 4;      { short or long vertical delta, data apart }
  IK_DLTA8 = 5;      { short or long vertical delta, data inline }
  IK_DLTAJ = 6;      { method 74, "J": Eric Graham's }
  IK_DLTAD = 7;      { method 100: long vertical runs }
  IK_DLTAE = 8;      { method 101: word vertical runs }
  IK_DLTAL = 9;      { method 108 }
  IK_LAST = IK_DLTAL;

type
  TIffChunk = record
    dataStart, dataEnd: SizeInt;
    sub: Integer;                    { IK_* }
    width, height, planes: Integer;
    interleave: Integer;             { ANHD: 0 = two frames back, 1 = one back }
    xorMode: Boolean;                { ANHD bits, bit 1 }
    bits: Int64;                     { ANHD bits: bit 0 long data (methods 7, 8, 108) }
  end;
  TIffChunks = array of TIffChunk;

  TTokenModel = class
  private
    tt: array[0..2] of TCounters;
    mx: TMixer;
    mm: TMatchModel;
  public
    constructor Create(tableBits: Integer);
    function Token(cd: TCoder; v, kind, c1, c2: Integer): Integer;
  end;

  { An ANIM's bitmaps: two buffers (players draw into the one not shown) }
  TAnimState = class
    w, h, np, rowBytes: Integer;
    buf: array[0..1] of TBytes;      { planes * h * rowBytes, plane-major }
    last: Integer;                   { the buffer shown last }
    deltas: Integer;
    constructor Create(aw, ah, anp: Integer);
  end;

function FindIffChunks(const d: TBytes): TIffChunks;
function IsDelta(sub: Integer): Boolean; inline;

procedure CodeIffChunk(cd: TCoder; tm: TTokenModel; pm: TDibModel; st: TAnimState;
                       const c: TIffChunk; var data: TBytes; len: SizeInt);

implementation

const
  NONE = 256;
  K_PTR = 1; K_OPCNT = 2; K_OP = 3; K_SAMECNT = 4; K_TRAIL = 5; K_RLE = 6;
  M_BODY = 0; M_SAME = 1; M_UNIQ = 2; M_XSAME = 3; M_XUNIQ = 4; M_RAW = 5;

function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

function Be16(const d: TBytes; p: SizeInt): Integer; inline;
begin
  Result := (d[p] shl 8) or d[p + 1];
end;

function Be32(const d: TBytes; p: SizeInt): Int64; inline;
begin
  Result := (Int64(d[p]) shl 24) or (Int64(d[p + 1]) shl 16) or (Int64(d[p + 2]) shl 8) or d[p + 3];
end;

function IsId(const d: TBytes; p: SizeInt; const id: string): Boolean;
begin
  Result := (p + 4 <= Length(d)) and (d[p] = Ord(id[1])) and (d[p + 1] = Ord(id[2]))
    and (d[p + 2] = Ord(id[3])) and (d[p + 3] = Ord(id[4]));
end;

{ ---------------- finding the chunks ---------------- }

type
  TFindState = record
    w, h, np, masking, comp: Integer;
    haveBmhd: Boolean;
    op, interleave: Integer;
    xorMode: Boolean;
    bits: Int64;
  end;

procedure WalkForm(const d: TBytes; q, stop: SizeInt; var fs: TFindState;
                   var r: TIffChunks; var n: Integer; depth: Integer);
var sz: Int64; c: TIffChunk;   { 32-bit size: Int64, no wrap on i386 }
begin
  while q + 8 <= stop do begin
    sz := Be32(d, q + 4);
    if q + 8 + sz > stop then Exit;
    if IsId(d, q, 'FORM') then begin
      if (depth < 3) and (sz >= 4) then begin
        fs.op := -1; fs.interleave := 0; fs.xorMode := False; fs.bits := 0;
        WalkForm(d, q + 12, q + 8 + sz, fs, r, n, depth + 1);
      end;
    end else if IsId(d, q, 'BMHD') and (sz >= 20) then begin
      if not fs.haveBmhd then begin
        fs.w := Be16(d, q + 8); fs.h := Be16(d, q + 10);
        fs.np := d[q + 16]; fs.masking := d[q + 17]; fs.comp := d[q + 18];
        fs.haveBmhd := True;
      end;
    end else if IsId(d, q, 'ANHD') and (sz >= 24) then begin
      fs.op := d[q + 8];
      { operation, mask, w, h, x, y, abstime, reltime, interleave, pad, bits }
      fs.interleave := d[q + 8 + 18];
      fs.bits := Be32(d, q + 8 + 20);
      fs.xorMode := (fs.bits and 2) <> 0;
    end else if (IsId(d, q, 'BODY') or IsId(d, q, 'DLTA')) and fs.haveBmhd and (sz > 0)
            and (fs.w > 0) and (fs.h > 0) and (fs.np >= 1) and (fs.np <= 8)
            and (SizeInt(fs.w) * fs.h <= SizeInt(1) shl 24) then begin
      c.dataStart := q + 8; c.dataEnd := q + 8 + sz;
      c.width := fs.w; c.height := fs.h; c.planes := fs.np;
      { a mask plane follows the colour planes in each row of a BODY: walked
        as one more plane (deltas leave it alone) }
      if (fs.masking = 1) and IsId(d, q, 'BODY') then c.planes := fs.np + 1;
      c.interleave := fs.interleave; c.xorMode := fs.xorMode; c.bits := fs.bits;
      c.sub := -1;
      if IsId(d, q, 'BODY') then begin
        if fs.comp = 1 then c.sub := IK_BODY_RLE
        else if fs.comp = 0 then c.sub := IK_BODY_RAW;
      end else
        case fs.op of
          5: c.sub := IK_DLTA5;
          3: c.sub := IK_DLTA3;
          7: c.sub := IK_DLTA7;
          8: c.sub := IK_DLTA8;
          74: c.sub := IK_DLTAJ;
          100: c.sub := IK_DLTAD;
          101: c.sub := IK_DLTAE;
          108: c.sub := IK_DLTAL;
        end;
      if c.sub >= 0 then begin
        if n >= Length(r) then SetLength(r, n * 2 + 16);
        r[n] := c; Inc(n);
      end;
    end;
    q := q + 8 + sz + (sz and 1);
  end;
end;

function IsDelta(sub: Integer): Boolean; inline;
begin
  Result := sub >= IK_DLTA5;
end;

function FindIffChunks(const d: TBytes): TIffChunks;
var n: Integer; fs: TFindState; stop: Int64;
begin
  Result := nil; n := 0;
  if (Length(d) < 12) or not IsId(d, 0, 'FORM') or not IsId(d, 8, 'ANIM') then Exit;
  fs := Default(TFindState);
  stop := 8 + Be32(d, 4);
  if stop > Length(d) then stop := Length(d);
  WalkForm(d, 12, stop, fs, Result, n, 0);
  SetLength(Result, n);
end;

{ ---------------- the token model ---------------- }

constructor TTokenModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(tt) do tt[i].Init(tableBits, 60);
  mx.Init(Length(tt) + 2, 16 * 8, 1, 11);
  mm.Init(18);
end;

function TTokenModel.Token(cd: TCoder; v, kind, c1, c2: Integer): Integer;
var b, bit, node, j, p, e: Integer; idx: array[0..2] of SizeInt; h: array[0..2] of QWord;
begin
  e := mm.Expected(0);
  h[0] := Hash(kind, 0);
  h[1] := Hash(kind * 65536 + c1, 1);
  h[2] := Hash(Hash(kind * 65536 + c1, c2), 2);
  node := 1;
  for b := 7 downto 0 do begin
    for j := 0 to 2 do begin
      idx[j] := Hash(h[j], node) and tt[j].mask;
      mx.Add(Stretch(tt[j].P12(idx[j])));
    end;
    mx.Add(mm.Input(e, 8, node, b));
    mx.Add(256);
    p := mx.Mix((kind and 15) * 8 + (7 - b));
    bit := cd.Code((v shr b) and 1, p);
    for j := 0 to 2 do tt[j].Update(idx[j], bit);
    mx.Update(bit);
    mm.Learn(bit);
    node := node * 2 + bit;
  end;
  Result := node and 255;
  mm.Update(Result);
end;

{ ---------------- the state ---------------- }

constructor TAnimState.Create(aw, ah, anp: Integer);
var i: Integer;
begin
  inherited Create;
  w := aw; h := ah; np := anp;
  rowBytes := ((w + 15) div 16) * 2;
  for i := 0 to 1 do begin
    buf[i] := nil;
    SetLength(buf[i], SizeInt(np) * h * rowBytes);
  end;
  last := 0; deltas := 0;
end;

{ ---------------- the walk ---------------- }

type
  TWalk = record
    cd: TCoder;
    tm: TTokenModel;
    pm: TDibModel;
    st: TAnimState;
    tgt: TBytes;          { the buffer being changed }
    old: TBytes;          { it, before }
    shown: TBytes;        { the frame shown before this one }
    buf: TBytes;
    pos, len: SizeInt;
    done: array of Boolean;   { random access walks: the bytes coded so far }
    function More(k: SizeInt): Boolean; inline;
    function TB(kind, c1, c2: Integer): Integer;
    { random access: the byte at `at`, coded the first time it is asked
      for (a token, or a bitplane byte at plane p, column x, row y),
      known after; -1 outside the data }
    function TA(at: SizeInt; kind, c1, c2: Integer): Integer;
    function PA(at: SizeInt; p, x, y, mode: Integer; xorIt: Boolean): Integer;
    { big-endian structure words at `at`; -1 if any byte is outside }
    function W16(at: SizeInt; kind, c: Integer): Int64;
    function W32(at: SizeInt; kind, c: Integer): Int64;
    { a bitplane byte at an offset into the interleaved bitmap (rows of all
      planes, as ILBM keeps them), or at a byte of plane p }
    function PIL(at: SizeInt; off: Int64; mode: Integer; xorIt: Boolean): Integer;
    function PPL(at: SizeInt; p: Integer; off: Int64; mode: Integer; xorIt: Boolean): Integer;
    { the bitmap byte at an interleaved offset set to v (a run's repeat) }
    procedure FillIL(off: Int64; v: Integer; xorIt: Boolean);
    { a bitplane byte: plane p, byte column x, row y; returns the byte coded }
    function PX(p, x, y, mode: Integer; xorIt: Boolean): Integer;
  end;

function TWalk.More(k: SizeInt): Boolean; inline;
begin
  Result := pos + k <= len;
end;

function TWalk.TB(kind, c1, c2: Integer): Integer;
var v: Integer;
begin
  if cd.encoding then v := buf[pos] else v := 0;
  Result := tm.Token(cd, v, kind, c1, c2);
  buf[pos] := Result;
  Inc(pos);
end;

function TWalk.PX(p, x, y, mode: Integer; xorIt: Boolean): Integer;
var c: array[0..8] of Integer; i, plane: SizeInt; v, rb: Integer; inside: Boolean;
begin
  rb := st.rowBytes;
  inside := (p >= 0) and (p < st.np) and (x >= 0) and (x < rb) and (y >= 0) and (y < st.h);
  c[0] := mode;
  if inside then begin
    plane := SizeInt(p) * st.h * rb;
    i := plane + SizeInt(y) * rb + x;
    c[1] := old[i];
    if y > 0 then c[2] := tgt[i - rb] else c[2] := NONE;
    if x > 0 then c[3] := tgt[i - 1] else c[3] := NONE;
    if p > 0 then c[4] := tgt[i - SizeInt(st.h) * rb] else c[4] := NONE;
    c[5] := shown[i];
    c[6] := c[4];
    c[7] := c[5]; c[8] := c[2];
  end else begin
    i := 0;
    for v := 1 to 8 do c[v] := NONE;
  end;
  if cd.encoding then v := buf[pos] else v := 0;
  Result := pm.Code(cd, v, c);
  buf[pos] := Result;
  Inc(pos);
  if inside then begin
    if xorIt then tgt[i] := old[i] xor Result else tgt[i] := Result;
  end;
end;

function TWalk.TA(at: SizeInt; kind, c1, c2: Integer): Integer;
var v: Integer;
begin
  if (at < 0) or (at >= len) then Exit(-1);
  if done[at] then Exit(buf[at]);
  if cd.encoding then v := buf[at] else v := 0;
  Result := tm.Token(cd, v, kind, c1, c2);
  buf[at] := Result;
  done[at] := True;
end;

function TWalk.PA(at: SizeInt; p, x, y, mode: Integer; xorIt: Boolean): Integer;
var c: array[0..8] of Integer; i: SizeInt; v, rb: Integer; inside: Boolean;
begin
  if (at < 0) or (at >= len) then Exit(-1);
  rb := st.rowBytes;
  inside := (p >= 0) and (p < st.np) and (x >= 0) and (x < rb) and (y >= 0) and (y < st.h);
  i := 0;
  if inside then i := SizeInt(p) * st.h * rb + SizeInt(y) * rb + x;
  if done[at] then Result := buf[at]
  else begin
    c[0] := mode;
    if inside then begin
      c[1] := old[i];
      if y > 0 then c[2] := tgt[i - rb] else c[2] := NONE;
      if x > 0 then c[3] := tgt[i - 1] else c[3] := NONE;
      if p > 0 then c[4] := tgt[i - SizeInt(st.h) * rb] else c[4] := NONE;
      c[5] := shown[i];
      c[6] := c[4];
      c[7] := c[5]; c[8] := c[2];
    end else
      for v := 1 to 8 do c[v] := NONE;
    if cd.encoding then v := buf[at] else v := 0;
    Result := pm.Code(cd, v, c);
    buf[at] := Result;
    done[at] := True;
  end;
  if inside then begin
    if xorIt then tgt[i] := old[i] xor Result else tgt[i] := Result;
  end;
end;

function TWalk.W16(at: SizeInt; kind, c: Integer): Int64;
var a, b: Integer;
begin
  a := TA(at, kind, c, 0);
  if a < 0 then Exit(-1);
  b := TA(at + 1, kind, c + 1, a);
  if b < 0 then Exit(-1);
  Result := a * 256 + b;
end;

function TWalk.W32(at: SizeInt; kind, c: Integer): Int64;
var a, b: Int64;
begin
  a := W16(at, kind, c);
  if a < 0 then Exit(-1);
  b := W16(at + 2, kind, c + 2);
  if b < 0 then Exit(-1);
  Result := a * 65536 + b;
end;

function TWalk.PIL(at: SizeInt; off: Int64; mode: Integer; xorIt: Boolean): Integer;
var pitch, r: Int64;
begin
  pitch := Int64(st.rowBytes) * st.np;
  if (off < 0) or (pitch <= 0) or (off div pitch >= st.h) then
    Exit(PA(at, -1, 0, 0, mode, xorIt));
  r := off mod pitch;
  Result := PA(at, r div st.rowBytes, r mod st.rowBytes, off div pitch, mode, xorIt);
end;

function TWalk.PPL(at: SizeInt; p: Integer; off: Int64; mode: Integer; xorIt: Boolean): Integer;
begin
  if (off < 0) or (off div st.rowBytes >= st.h) then
    Exit(PA(at, -1, 0, 0, mode, xorIt));
  Result := PA(at, p, off mod st.rowBytes, off div st.rowBytes, mode, xorIt);
end;

procedure TWalk.FillIL(off: Int64; v: Integer; xorIt: Boolean);
var pitch, r: Int64; i: SizeInt;
begin
  pitch := Int64(st.rowBytes) * st.np;
  if (off < 0) or (pitch <= 0) or (off div pitch >= st.h) then Exit;
  r := off mod pitch;
  i := SizeInt(r div st.rowBytes) * st.h * st.rowBytes + SizeInt(off div pitch) * st.rowBytes + r mod st.rowBytes;
  if xorIt then tgt[i] := old[i] xor v else tgt[i] := v;
end;

procedure WalkBody(var wk: TWalk; rle: Boolean);
var y, p, x, n, k, v, last: Integer;
begin
  last := 0;
  for y := 0 to wk.st.h - 1 do
    for p := 0 to wk.st.np - 1 do begin
      x := 0;
      while x < wk.st.rowBytes do begin
        if not wk.More(1) then Exit;
        if not rle then begin wk.PX(p, x, y, M_RAW, False); Inc(x); Continue; end;
        n := wk.TB(K_RLE, last, Ord(x = 0));
        last := n;
        if n < 128 then begin
          for k := 0 to n do begin
            if not wk.More(1) then Exit;
            wk.PX(p, x, y, M_BODY, False); Inc(x);
          end;
        end else if n > 128 then begin
          if not wk.More(1) then Exit;
          v := wk.PX(p, x, y, M_BODY, False);
          for k := 1 to 256 - n do begin
            if (x + k < wk.st.rowBytes) then
              wk.tgt[SizeInt(p) * wk.st.h * wk.st.rowBytes + SizeInt(y) * wk.st.rowBytes + x + k] := v;
          end;
          x := x + 257 - n;
        end;
      end;
    end;
end;

procedure WalkDelta5(var wk: TWalk; xorIt: Boolean);
var ptr: array[0..15] of Int64; order: array[0..7] of Integer;
    i, j, k, p, n, x, y, opcnt, op, cnt, v, lastOp, lastCnt: Integer; b: Integer;
    sameMode, uniqMode: Integer;
begin
  if not wk.More(64) then Exit;
  for i := 0 to 15 do begin
    ptr[i] := 0;
    for j := 0 to 3 do begin
      b := wk.TB(K_PTR, i * 4 + j, 0);
      ptr[i] := (ptr[i] shl 8) or b;
    end;
  end;
  { the planes in the order of their data }
  FillChar(order, SizeOf(order), 0);
  n := 0;
  for p := 0 to wk.st.np - 1 do
    if (ptr[p] >= 64) and (ptr[p] < wk.len) then begin
      k := n;
      while (k > 0) and (ptr[order[k - 1]] > ptr[p]) do begin order[k] := order[k - 1]; Dec(k); end;
      order[k] := p; Inc(n);
    end;
  if xorIt then begin sameMode := M_XSAME; uniqMode := M_XUNIQ; end
  else begin sameMode := M_SAME; uniqMode := M_UNIQ; end;
  lastOp := 0; lastCnt := 0;
  for i := 0 to n - 1 do begin
    p := order[i];
    if ptr[p] < wk.pos then Continue;       { shared or overlapping data: left as it is }
    while wk.pos < ptr[p] do wk.TB(K_TRAIL, 0, 0);
    for x := 0 to wk.st.rowBytes - 1 do begin
      if not wk.More(1) then Exit;
      opcnt := wk.TB(K_OPCNT, Ord(x = 0), 0);
      y := 0;
      for k := 1 to opcnt do begin
        if not wk.More(1) then Exit;
        op := wk.TB(K_OP, lastOp, 0);
        lastOp := op;
        if op = 0 then begin
          if not wk.More(2) then Exit;
          cnt := wk.TB(K_SAMECNT, lastCnt, 0);
          lastCnt := cnt;
          v := wk.PX(p, x, y, sameMode, xorIt);
          for j := 1 to cnt - 1 do
            if (y + j < wk.st.h) then begin
              if xorIt then
                wk.tgt[SizeInt(p) * wk.st.h * wk.st.rowBytes + SizeInt(y + j) * wk.st.rowBytes + x] :=
                  wk.old[SizeInt(p) * wk.st.h * wk.st.rowBytes + SizeInt(y + j) * wk.st.rowBytes + x] xor v
              else
                wk.tgt[SizeInt(p) * wk.st.h * wk.st.rowBytes + SizeInt(y + j) * wk.st.rowBytes + x] := v;
            end;
          y := y + cnt;
        end else if op < 128 then
          y := y + op
        else begin
          for j := 1 to op and 127 do begin
            if not wk.More(1) then Exit;
            wk.PX(p, x, y, uniqMode, xorIt);
            Inc(y);
          end;
        end;
      end;
    end;
  end;
end;

{ ---------------- the other delta methods (random access) ----------------

  Each walk follows its method as a player would (FFmpeg's iff.c reads
  them the same way): the pointers, counts and opcodes are tokens, the
  data bytes are bitplane bytes at the place they go, with that place as
  context. A byte is coded where the walk first needs it; whatever no walk
  reached (padding, unused tables, damage) is coded after, in order. }

const
  K_OFS = 7; K_CNT = 8; K_TYPE = 9; K_FLAG = 10;

{ the signed value of a 16- or 32-bit word }
function S16(v: Int64): Int64; inline;
begin
  if v >= $8000 then Result := v - $10000 else Result := v;
end;

function S32(v: Int64): Int64; inline;
begin
  if v >= $80000000 then Result := v - $100000000 else Result := v;
end;

{ method 3: per plane, (offset, word) pairs and (negative offset, count,
  words) runs along the plane's bytes, to 0xFFFF }
procedure WalkDelta3(var wk: TWalk; xorIt: Boolean);
var k, i: Integer; ptr, q, pos, off, cnt: Int64;
  function Word2(at: SizeInt; bp: Int64; mode: Integer): Boolean;
  begin
    Result := (wk.PPL(at, k, bp, mode, xorIt) >= 0) and (wk.PPL(at + 1, k, bp + 1, mode, xorIt) >= 0);
  end;
begin
  for k := 0 to wk.st.np - 1 do begin
    ptr := wk.W32(4 * k, K_PTR, 4 * k);
    if (ptr <= 0) or (ptr >= wk.len) then Continue;
    q := ptr; pos := 0;
    while q + 4 <= wk.len do begin
      off := wk.W16(q, K_OFS, 0);
      if (off < 0) or (off = $FFFF) then Break;
      q := q + 2;
      if off < $8000 then begin
        pos := pos + off * 2;
        if not Word2(q, pos, M_UNIQ) then Exit;
        q := q + 2;
      end else begin
        cnt := wk.W16(q, K_CNT, 0);
        if cnt < 0 then Exit;
        q := q + 2;
        pos := pos + 2 * (-(S16(off) + 2));
        for i := 1 to cnt do begin
          if q + 2 > wk.len then Exit;
          pos := pos + 2;
          if not Word2(q, pos, M_SAME) then Exit;
          q := q + 2;
        end;
      end;
    end;
  end;
end;

{ methods 7 (data apart: 8 opcode lists, then 8 data lists) and 8 (data
  inline, the counts and opcodes as wide as the data): per plane, per
  column of words (short) or longwords (long), opcodes down the rows }
procedure WalkVertical(var wk: TWalk; inline8, long, xorIt: Boolean);
var k, j, b, nb, colBytes, ncol, lastOp, lastCnt, sameMode, uniqMode: Integer;
    optr, dptr, q, dq, cnt, op, rc, n, y, r, skip, i, wide: Int64;
    half: Boolean; v: array[0..3] of Integer;
  function Num(at: SizeInt; kind, c: Integer; w: Integer): Int64;
  begin
    if w = 1 then Result := wk.TA(at, kind, c, 0)
    else if w = 2 then Result := wk.W16(at, kind, c)
    else Result := wk.W32(at, kind, c);
  end;
  { the data unit at `at` to row y of this column; False outside }
  function DoUnit(at: SizeInt; mode: Integer): Boolean;
  var bb: Integer;
  begin
    for bb := 0 to colBytes - 1 do begin
      if bb < nb then v[bb] := wk.PA(at + bb, k, j * colBytes + bb, y, mode, xorIt)
      else v[bb] := wk.TA(at + bb, K_TRAIL, 0, 2);      { the half column's unused word }
      if v[bb] < 0 then Exit(False);
    end;
    Result := True;
  end;
begin
  FillChar(v, SizeOf(v), 0);
  if xorIt then begin sameMode := M_XSAME; uniqMode := M_XUNIQ; end
  else begin sameMode := M_SAME; uniqMode := M_UNIQ; end;
  if long then begin colBytes := 4; ncol := (wk.st.w + 31) shr 5; end
  else begin colBytes := 2; ncol := (wk.st.w + 15) shr 4; end;
  half := long and (wk.st.rowBytes <> ncol * 4);
  lastOp := 0; lastCnt := 0;
  for k := 0 to wk.st.np - 1 do begin
    optr := wk.W32(4 * k, K_PTR, 4 * k);
    if (optr <= 0) or (optr >= wk.len) then Continue;
    dptr := 0;
    if not inline8 then begin
      dptr := wk.W32(32 + 4 * k, K_PTR, 32 + 4 * k);
      if (dptr < 0) or (dptr >= wk.len) then Exit;
    end;
    q := optr; dq := dptr;
    for j := 0 to ncol - 1 do begin
      if half and (j = ncol - 1) then nb := 2 else nb := colBytes;
      if inline8 then begin
        if long then wide := 4 else wide := 2;
        if half and (j = ncol - 1) then skip := $8000 else if long then skip := $80000000 else skip := $8000;
      end else begin
        wide := 1; skip := $80;
      end;
      cnt := Num(q, K_OPCNT, Ord(j = 0), wide);
      if cnt < 0 then Exit;
      q := q + wide;
      y := 0;
      i := 0;
      while i < cnt do begin
        Inc(i);
        op := Num(q, K_OP, lastOp and 255, wide);
        if op < 0 then Exit;
        q := q + wide;
        lastOp := op and 255;
        if op = 0 then begin
          if inline8 and half and (j = ncol - 1) then begin
            rc := Num(q, K_SAMECNT, lastCnt, 2); q := q + 2;
          end else begin
            rc := Num(q, K_SAMECNT, lastCnt, wide); q := q + wide;
          end;
          if rc < 0 then Exit;
          lastCnt := rc and 255;
          if inline8 then begin
            if half and (j = ncol - 1) then begin
              for b := 0 to 1 do begin v[b] := wk.PA(q + b, k, j * colBytes + b, y, sameMode, xorIt); if v[b] < 0 then Exit; end;
              q := q + 2;
            end else begin
              if not DoUnit(q, sameMode) then Exit;
              q := q + colBytes;
            end;
          end else begin
            if not DoUnit(dq, sameMode) then Exit;
            dq := dq + colBytes;
          end;
          for r := 1 to Min(rc - 1, Int64(wk.st.h)) do
            if y + r < wk.st.h then
              for b := 0 to nb - 1 do
                wk.FillIL((y + r) * Int64(wk.st.rowBytes) * wk.st.np + Int64(k) * wk.st.rowBytes + j * colBytes + b, v[b], xorIt);
          y := y + rc;
        end else if op < skip then
          y := y + op
        else begin
          n := op - skip;
          for r := 1 to n do begin
            if inline8 then begin
              if half and (j = ncol - 1) then begin
                for b := 0 to 1 do if wk.PA(q + b, k, j * colBytes + b, y, uniqMode, xorIt) < 0 then Exit;
                q := q + 2;
              end else begin
                if not DoUnit(q, uniqMode) then Exit;
                q := q + colBytes;
              end;
            end else begin
              if not DoUnit(dq, uniqMode) then Exit;
              dq := dq + colBytes;
            end;
            Inc(y);
          end;
        end;
        if y > Int64(wk.st.h) * 4 + 65536 then Exit;   { nonsense: the rest stays as bytes }
      end;
    end;
  end;
end;

{ method 74 ("J"): groups of bytes at offsets into the interleaved bitmap,
  type 1 down a column through the planes, type 2 rows of bytes }
procedure WalkDeltaJ(var wk: TWalk);
var q, t, flag, cols, groups, rows, bytes, g, b, dd, r, off, il, noff, pitch: Int64;
    ppb, kludge: Integer; xorIt: Boolean;
  function Map(o: Int64): Int64;
  begin
    if kludge > 0 then Result := (o div 40) * pitch + (o mod 40) - kludge
    else Result := (o div ppb) * pitch + (o mod ppb);
  end;
begin
  pitch := Int64(wk.st.rowBytes) * wk.st.np;
  ppb := (wk.st.w + 7) div 8;
  if wk.st.w < 320 then kludge := (320 - wk.st.w) div 16 else kludge := 0;
  q := 0;
  while q + 2 <= wk.len do begin
    t := wk.W16(q, K_TYPE, 0);
    if t < 0 then Exit;
    q := q + 2;
    if t = 1 then begin
      flag := wk.W16(q, K_FLAG, 0); cols := wk.W16(q + 2, K_CNT, 0); groups := wk.W16(q + 4, K_CNT, 2);
      if (flag < 0) or (cols < 0) or (groups < 0) then Exit;
      q := q + 6;
      xorIt := flag <> 0;
      for g := 1 to groups do begin
        off := wk.W16(q, K_OFS, 0);
        if off < 0 then Exit;
        q := q + 2;
        if (cols * wk.st.np = 0) or (q + cols * wk.st.np > wk.len) then Exit;
        il := Map(off);
        for b := 1 to cols do
          for dd := 1 to wk.st.np do begin
            wk.PIL(q, il, M_UNIQ + 2 * Ord(xorIt), xorIt);
            q := q + 1;
            il := il + wk.st.rowBytes;
          end;
        if Odd(cols * wk.st.np) then q := q + 1;
      end;
    end else if t = 2 then begin
      flag := wk.W16(q, K_FLAG, 0); rows := wk.W16(q + 2, K_CNT, 0);
      bytes := wk.W16(q + 4, K_CNT, 2); groups := wk.W16(q + 6, K_CNT, 4);
      if (flag < 0) or (rows < 0) or (bytes < 0) or (groups < 0) then Exit;
      q := q + 8;
      xorIt := flag <> 0;
      for g := 1 to groups do begin
        off := wk.W16(q, K_OFS, 0);
        if off < 0 then Exit;
        q := q + 2;
        il := Map(off);
        for r := 0 to rows - 1 do
          for dd := 0 to wk.st.np - 1 do begin
            if (bytes = 0) or (q + bytes > wk.len) then Exit;
            noff := il + r * pitch + dd * wk.st.rowBytes;
            for b := 0 to bytes - 1 do begin
              wk.PIL(q, noff + b, M_UNIQ + 2 * Ord(xorIt), xorIt);
              q := q + 1;
            end;
          end;
        if Odd(rows * bytes * wk.st.np) then q := q + 1;
      end;
    end else
      Exit;
  end;
end;

{ methods 100 and 101: per plane, entries (opcode, offset): a value run
  down the rows, or that many values, longwords (100) or words (101) }
procedure WalkDeltaDE(var wk: TWalk; long: Boolean);
var k, b, unitB, sameMode, uniqMode: Integer; ptr, q, entries, e, opc, off, il, pitch, ppb, r: Int64;
    v: array[0..3] of Integer;
begin
  FillChar(v, SizeOf(v), 0);
  sameMode := M_SAME; uniqMode := M_UNIQ;
  pitch := Int64(wk.st.rowBytes) * wk.st.np;
  ppb := (wk.st.w + 7) div 8;
  if long then unitB := 4 else unitB := 2;
  for k := 0 to wk.st.np - 1 do begin
    ptr := wk.W32(4 * k, K_PTR, 4 * k);
    if (ptr <= 0) or (ptr >= wk.len) then Continue;
    q := ptr;
    if long then begin entries := wk.W32(q, K_CNT, 0); q := q + 4; end
    else begin entries := wk.W16(q, K_CNT, 0); q := q + 2; end;
    if entries < 0 then Exit;
    e := 0;
    while (e < entries) and (q + 2 + unitB <= wk.len) do begin
      Inc(e);
      if long then begin opc := wk.W32(q, K_OP, 0); q := q + 4; if opc >= 0 then opc := S32(opc); end
      else begin opc := wk.W16(q, K_OP, 0); q := q + 2; if opc >= 0 then opc := S16(opc); end;
      off := wk.W32(q, K_OFS, 0);
      if off < 0 then Exit;
      q := q + 4;
      il := (off div ppb) * pitch + (off mod ppb) + Int64(k) * wk.st.rowBytes;
      if opc >= 0 then begin
        for b := 0 to unitB - 1 do begin
          v[b] := wk.PIL(q + b, il + b, sameMode, False);
          if v[b] < 0 then Exit;
        end;
        q := q + unitB;
        for r := 1 to Min(opc - 1, Int64(wk.st.h)) do begin
          if (il + r * pitch) div pitch >= wk.st.h then Break;
          for b := 0 to unitB - 1 do wk.FillIL(il + r * pitch + b, v[b], False);
        end;
      end else
        for r := 0 to -opc - 1 do begin
          for b := 0 to unitB - 1 do
            if wk.PIL(q + b, il + r * pitch + b, uniqMode, False) < 0 then Exit;
          q := q + unitB;
        end;
    end;
  end;
end;

{ method 108: per plane, (offset, count) pairs (to 0xFFFF) and the data
  apart: a word repeated, or that many words, down (short) or across }
procedure WalkDeltaL(var wk: TWalk; bits: Int64);
var k, b: Integer; p0, p1, dq, oq, o, cnt, il, pitch, ppb, step, i: Int64; v: array[0..1] of Integer;
begin
  FillChar(v, SizeOf(v), 0);
  pitch := Int64(wk.st.rowBytes) * wk.st.np;
  ppb := (wk.st.w + 7) div 8;
  if (bits and 1) = 0 then step := ppb * wk.st.np else step := 2;
  for k := 0 to wk.st.np - 1 do begin
    p0 := wk.W32(4 * k, K_PTR, 4 * k);
    p1 := wk.W32(32 + 4 * k, K_PTR, 32 + 4 * k);
    if (p0 <= 0) or (p1 < 0) then Continue;
    dq := 2 * p0; oq := 2 * p1;
    if (dq >= wk.len) or (oq >= wk.len) then Exit;
    while oq + 4 <= wk.len do begin
      o := wk.W16(oq, K_OFS, 0);
      if (o < 0) or (o = $FFFF) then Break;
      cnt := wk.W16(oq + 2, K_CNT, 0);
      if cnt < 0 then Exit;
      oq := oq + 4;
      cnt := S16(cnt);
      il := ((2 * o) div ppb) * pitch + ((2 * o) mod ppb) + Int64(k) * wk.st.rowBytes;
      if cnt < 0 then begin
        for b := 0 to 1 do begin
          v[b] := wk.PIL(dq + b, il + b, M_SAME, False);
          if v[b] < 0 then Exit;
        end;
        dq := dq + 2;
        for i := 1 to -cnt - 1 do
          for b := 0 to 1 do wk.FillIL(il + i * step + b, v[b], False);
      end else
        for i := 0 to cnt - 1 do begin
          for b := 0 to 1 do
            if wk.PIL(dq + b, il + i * step + b, M_UNIQ, False) < 0 then Exit;
          dq := dq + 2;
        end;
    end;
  end;
end;

procedure CodeIffChunk(cd: TCoder; tm: TTokenModel; pm: TDibModel; st: TAnimState;
                       const c: TIffChunk; var data: TBytes; len: SizeInt);
var wk: TWalk; t, last: Integer; i: SizeInt;
begin
  wk.cd := cd; wk.tm := tm; wk.pm := pm; wk.st := st;
  if cd.encoding then wk.buf := data else begin wk.buf := nil; SetLength(wk.buf, len); end;
  wk.pos := 0; wk.len := len;
  wk.done := nil;
  if IsDelta(c.sub) then begin
    Inc(st.deltas);
    if c.interleave = 1 then t := st.last
    else t := st.deltas and 1;          { the first delta draws into buffer 1 }
    wk.shown := Copy(st.buf[st.last], 0, Length(st.buf[st.last]));
  end else begin
    t := 0;
    wk.shown := Copy(st.buf[0], 0, Length(st.buf[0]));
  end;
  wk.tgt := st.buf[t];
  wk.old := Copy(wk.tgt, 0, Length(wk.tgt));
  if c.sub <= IK_DLTA5 then begin
    case c.sub of
      IK_BODY_RLE: WalkBody(wk, True);
      IK_BODY_RAW: WalkBody(wk, False);
      IK_DLTA5: WalkDelta5(wk, c.xorMode);
    end;
    last := 0;
    while wk.pos < wk.len do last := wk.TB(K_TRAIL, last, 1);
  end else begin
    SetLength(wk.done, len);
    case c.sub of
      IK_DLTA3: WalkDelta3(wk, c.xorMode);
      IK_DLTA7: WalkVertical(wk, False, (c.bits and 1) <> 0, c.xorMode);
      IK_DLTA8: WalkVertical(wk, True, (c.bits and 1) <> 0, c.xorMode);
      IK_DLTAJ: WalkDeltaJ(wk);
      IK_DLTAD: WalkDeltaDE(wk, True);
      IK_DLTAE: WalkDeltaDE(wk, False);
      IK_DLTAL: WalkDeltaL(wk, c.bits);
    end;
    { what no walk reached, in order }
    last := 0;
    for i := 0 to len - 1 do
      if not wk.done[i] then last := wk.TA(i, K_TRAIL, last, 1);
  end;
  if not IsDelta(c.sub) then begin
    { the first frame is in both buffers }
    st.buf[1] := Copy(st.buf[0], 0, Length(st.buf[0]));
    st.last := 0; st.deltas := 0;
  end else st.last := t;
  data := wk.buf;
end;

end.
