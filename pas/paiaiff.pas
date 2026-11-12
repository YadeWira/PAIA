{ IFF ANIM (Amiga): finding the frames' pixel data, and coding it.

  An ANIM is a FORM ANIM of FORM ILBMs: the first holds the first frame
  (BMHD, CMAP, BODY: bitplanes, row by row, plane by plane, usually
  ByteRun1-compressed), each other one a delta (ANHD, DLTA). The deltas
  taken are method 5, Byte Vertical Delta, by far the most used: for each
  plane a pointer, and for each column of bytes a list of operations going
  down the rows (skip rows, repeat a byte, or take bytes as they are).

  As for FLICs, the bytes of a BODY and of a DLTA are coded in their own
  order, field by field: structure to a token model, bitplane bytes to a
  model that sees the bitmaps as the frames build them (what the byte
  replaces, the frame before, the neighbours in its plane, the plane below
  at the same place). Exact by construction. The frames are double
  buffered, as players do: a delta changes the frame two back, unless its
  ANHD says one back.

  Not taken (they stay as plain bytes): other delta methods, BODYs with a
  mask plane or other compression, chunky (deep) ILBMs. }
unit paiaiff;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiaiff: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiaiff: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith, paiadib;

const
  IK_BODY_RAW = 0;
  IK_BODY_RLE = 1;
  IK_DLTA5 = 2;

type
  TIffChunk = record
    dataStart, dataEnd: SizeInt;
    sub: Integer;                    { IK_* }
    width, height, planes: Integer;
    interleave: Integer;             { ANHD: 0 = two frames back, 1 = one back }
    xorMode: Boolean;                { ANHD bits, bit 1 }
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
        fs.op := -1; fs.interleave := 0; fs.xorMode := False;
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
      fs.xorMode := (Be32(d, q + 8 + 20) and 2) <> 0;
    end else if (IsId(d, q, 'BODY') or IsId(d, q, 'DLTA')) and fs.haveBmhd and (sz > 0)
            and (fs.w > 0) and (fs.h > 0) and (fs.np >= 1) and (fs.np <= 8)
            and (SizeInt(fs.w) * fs.h <= SizeInt(1) shl 24) then begin
      c.dataStart := q + 8; c.dataEnd := q + 8 + sz;
      c.width := fs.w; c.height := fs.h; c.planes := fs.np;
      c.interleave := fs.interleave; c.xorMode := fs.xorMode;
      c.sub := -1;
      if IsId(d, q, 'BODY') then begin
        if (fs.masking <> 1) and (fs.comp = 1) then c.sub := IK_BODY_RLE
        else if (fs.masking <> 1) and (fs.comp = 0) then c.sub := IK_BODY_RAW;
      end else if fs.op = 5 then c.sub := IK_DLTA5;
      if c.sub >= 0 then begin
        if n >= Length(r) then SetLength(r, n * 2 + 16);
        r[n] := c; Inc(n);
      end;
    end;
    q := q + 8 + sz + (sz and 1);
  end;
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
    function More(k: SizeInt): Boolean; inline;
    function TB(kind, c1, c2: Integer): Integer;
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

procedure CodeIffChunk(cd: TCoder; tm: TTokenModel; pm: TDibModel; st: TAnimState;
                       const c: TIffChunk; var data: TBytes; len: SizeInt);
var wk: TWalk; t, last: Integer;
begin
  wk.cd := cd; wk.tm := tm; wk.pm := pm; wk.st := st;
  if cd.encoding then wk.buf := data else begin wk.buf := nil; SetLength(wk.buf, len); end;
  wk.pos := 0; wk.len := len;
  if c.sub = IK_DLTA5 then begin
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
  case c.sub of
    IK_BODY_RLE: WalkBody(wk, True);
    IK_BODY_RAW: WalkBody(wk, False);
    IK_DLTA5: WalkDelta5(wk, c.xorMode);
  end;
  last := 0;
  while wk.pos < wk.len do last := wk.TB(K_TRAIL, last, 1);
  if c.sub <> IK_DLTA5 then begin
    { the first frame is in both buffers }
    st.buf[1] := Copy(st.buf[0], 0, Length(st.buf[0]));
    st.last := 0; st.deltas := 0;
  end else st.last := t;
  data := wk.buf;
end;

end.
