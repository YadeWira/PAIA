{ ANI (Windows animated cursors): finding the frames' bitmaps, and coding
  them.

  An ANI is a RIFF "ACON": a header (anih), optional rates and sequence,
  and a LIST "fram" of "icon" chunks, each an ICO or CUR file whose images
  are device-independent bitmaps (or PNG). A DIB is not compressed: its
  pixel rows (the colour bitmap, then the 1-bit AND mask) are coded byte
  by byte in their own order, each byte knowing its channel and place:
  so it comes back exactly, by construction. The predictions: the same
  channel's neighbours, a gradient, the channels of the same pixel coded
  before it, and the same byte in the previous frame of the same shape.
  Headers, palettes and every other chunk stay with the plain bytes. }
unit paiadib;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiadib: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiadib: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith;

type
  TDib = record
    dataStart, dataEnd: SizeInt;   { the pixel rows: colour, then mask }
    width, height, bpp: Integer;   { height: of the colour bitmap }
  end;
  TDibs = array of TDib;

  TDibModel = class
  private
    t: array[0..8] of TCounters;
    mx: TMixer;
    apm: TApm;
    mm: TMatchModel;
  public
    constructor Create(tableBits: Integer);
    { a byte, from its context: c[0] a channel or mode (0-7), c[1..8]
      values (256: none) whose roles are paiadib's: left, up, up-left,
      up-right, the previous frame, a prediction, and two more together }
    function Code(cd: TCoder; v: Integer; const c: array of Integer): Integer;
  end;

{ The DIBs of the ANI at the start of d, if it is one. }
function FindDibs(const d: TBytes): TDibs;

{ Codes a DIB's pixel rows (decoding: fills `data`, `len` bytes); prev: the
  previous frame of the same shape, or nil. }
procedure CodeDib(cd: TCoder; m: TDibModel; const dib: TDib; var data: TBytes;
                  len: SizeInt; const prev: TBytes);

implementation

function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

function Le16(const d: TBytes; p: SizeInt): Integer; inline;
begin
  Result := d[p] or (d[p + 1] shl 8);
end;

function Le32(const d: TBytes; p: SizeInt): Int64; inline;
begin
  Result := Int64(d[p]) or (Int64(d[p + 1]) shl 8) or (Int64(d[p + 2]) shl 16)
            or (Int64(d[p + 3]) shl 24);
end;

function Stride(w, bpp: Integer): SizeInt; inline;
begin
  Result := ((SizeInt(w) * bpp + 31) div 32) * 4;
end;

{ ---------------- finding the bitmaps ---------------- }

procedure AddIcon(const d: TBytes; off, size: SizeInt; var r: TDibs; var n: Integer);
var cnt, k, w, h, bpp, colors: Integer; e, io, isz, hs, pix, need: SizeInt;
    comp: Int64; dib: TDib;
begin
  if size < 6 then Exit;
  if (Le16(d, off) <> 0) or not (Le16(d, off + 2) in [1, 2]) then Exit;
  cnt := Le16(d, off + 4);
  for k := 0 to cnt - 1 do begin
    e := off + 6 + 16 * SizeInt(k);
    if e + 16 > off + size then Exit;
    isz := Le32(d, e + 8);
    io := off + Le32(d, e + 12);
    if (io < off) or (isz < 40) or (io + isz > off + size) then Continue;
    hs := Le32(d, io);
    if hs <> 40 then Continue;                       { BITMAPINFOHEADER only; PNG stays }
    w := Integer(Le32(d, io + 4));
    h := Integer(Le32(d, io + 8));
    bpp := Le16(d, io + 14);
    comp := Le32(d, io + 16);
    if (comp <> 0) or (w < 1) or (w > 4096) or (h < 2) or (h > 8192) or
       not (bpp in [1, 4, 8, 16, 24, 32]) then Continue;
    h := h div 2;
    colors := Integer(Le32(d, io + 32));
    if (colors = 0) and (bpp <= 8) then colors := 1 shl bpp;
    if bpp > 8 then colors := 0;
    if colors > 256 then Continue;
    pix := io + hs + 4 * colors;
    need := Stride(w, bpp) * h + Stride(w, 1) * h;
    if pix >= io + isz then Continue;
    dib.dataStart := pix;
    dib.dataEnd := io + isz;
    if dib.dataEnd - pix > need then dib.dataEnd := pix + need;   { the rest stays as bytes }
    dib.width := w; dib.height := h; dib.bpp := bpp;
    if n >= Length(r) then SetLength(r, n * 2 + 16);
    r[n] := dib; Inc(n);
  end;
end;

procedure Walk(const d: TBytes; q, stop: SizeInt; var r: TDibs; var n: Integer; depth: Integer);
var sz: SizeInt;
begin
  while q + 8 <= stop do begin
    sz := Le32(d, q + 4);
    if q + 8 + sz > stop then Exit;
    if (d[q] = Ord('L')) and (d[q + 1] = Ord('I')) and (d[q + 2] = Ord('S')) and (d[q + 3] = Ord('T')) then begin
      if (depth < 4) and (sz >= 4) then Walk(d, q + 12, q + 8 + sz, r, n, depth + 1);
    end else if (d[q] = Ord('i')) and (d[q + 1] = Ord('c')) and (d[q + 2] = Ord('o')) and (d[q + 3] = Ord('n')) then
      AddIcon(d, q + 8, sz, r, n);
    q := q + 8 + sz + (sz and 1);
  end;
end;

function FindDibs(const d: TBytes): TDibs;
var n: Integer; stop: SizeInt;
begin
  Result := nil; n := 0;
  if (Length(d) < 12) or (d[0] <> Ord('R')) or (d[1] <> Ord('I')) or (d[2] <> Ord('F'))
     or (d[3] <> Ord('F')) or (d[8] <> Ord('A')) or (d[9] <> Ord('C')) or (d[10] <> Ord('O'))
     or (d[11] <> Ord('N')) then Exit;
  stop := 8 + Le32(d, 4);
  if stop > Length(d) then stop := Length(d);
  Walk(d, 12, stop, Result, n, 0);
  SetLength(Result, n);
end;

{ ---------------- the model ---------------- }

constructor TDibModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(t) do t[i].Init(tableBits, 255);
  mx.Init(Length(t) + 2, 8 * 8 * 2, 1, 11);
  apm.Init(8 * 256, 7);
  mm.Init(20);
end;

{ c: ch, L, U, UL, UR, P, gradient, cross-channel prediction, C0 delta }
function TDibModel.Code(cd: TCoder; v: Integer; const c: array of Integer): Integer;
var b, bit, node, sub, j, pm, pa, e, ch: Integer; base: array[0..8] of QWord;
    slot: array[0..8] of SizeInt;
begin
  ch := c[0];
  base[0] := ch;
  base[1] := Hash(ch * 512 + c[1], 1);
  base[2] := Hash(ch * 512 + c[2], 2);
  base[3] := Hash(Hash(ch * 512 + c[1], c[2]), 3);
  base[4] := Hash(ch * 512 + c[6], 4);
  base[5] := Hash(ch * 512 + c[5], 5);
  base[6] := Hash(Hash(ch * 512 + c[5], c[1]), 6);
  base[7] := Hash(Hash(ch * 512 + c[7], c[8]), 7);
  base[8] := Hash(Hash(ch * 512 + (c[1] shr 2), (c[2] shr 2) * 512 + (c[3] shr 2)), (c[4] shr 2) + 8 * 512);
  e := mm.Expected(0);
  FillChar(slot, SizeOf(slot), 0);
  node := 1; sub := 1;
  for b := 7 downto 0 do begin
    if (b = 7) or (b = 3) then begin
      for j := 0 to High(t) do slot[j] := (Hash(base[j], node) shl 4) and t[j].mask;
      sub := 1;
    end;
    for j := 0 to High(t) do mx.Add(Stretch(t[j].P12(slot[j] + sub)));
    mx.Add(mm.Input(e, 8, node, b));
    mx.Add(256);
    pm := mx.Mix(((ch and 7) * 8 + (7 - b)) * 2 + Ord(mm.len >= 16));
    pa := apm.Refine(pm, (ch and 7) * 256 + (node and 255));
    bit := cd.Code((v shr b) and 1, (pm + 3 * pa) div 4);
    for j := 0 to High(t) do t[j].Update(slot[j] + sub, bit);
    mx.Update(bit);
    apm.Update(bit);
    mm.Learn(bit);
    node := node * 2 + bit;
    sub := sub * 2 + bit;
  end;
  Result := node and 255;
  mm.Update(Result);
end;

{ ---------------- the walk ---------------- }

const
  NONE = 256;
  CH_PAD = 6;
  CH_MASK = 5;
  CH_TRAIL = 7;

procedure CodeDib(cd: TCoder; m: TDibModel; const dib: TDib; var data: TBytes;
                  len: SizeInt; const prev: TBytes);
var buf: TBytes; pos, rowLen, rowStart, base: SizeInt; y, k, step, ch, v, rows: Integer;
    c: array[0..8] of Integer; part, width, bpb: Integer;
  function At(p: SizeInt): Integer; inline;
  begin
    if (p >= 0) and (p < pos) then Result := buf[p] else Result := NONE;
  end;
  function PrevAt(p: SizeInt): Integer; inline;
  begin
    if (prev <> nil) and (p < Length(prev)) then Result := prev[p] else Result := NONE;
  end;
  function Clip(x: Integer): Integer; inline;
  begin
    if x < 0 then Result := 0 else if x > 255 then Result := 255 else Result := x;
  end;
begin
  if cd.encoding then buf := data else begin buf := nil; SetLength(buf, len); end;
  pos := 0;
  base := 0;
  for part := 0 to 1 do begin
    { part 0: the colour bitmap; part 1: the AND mask }
    if part = 0 then begin
      rowLen := Stride(dib.width, dib.bpp);
      if dib.bpp >= 8 then step := dib.bpp div 8 else step := 1;
      bpb := (dib.width * dib.bpp + 7) div 8;            { bytes of pixels in a row }
    end else begin
      rowLen := Stride(dib.width, 1);
      step := 1;
      bpb := (dib.width + 7) div 8;
    end;
    rows := dib.height;
    for y := 0 to rows - 1 do begin
      rowStart := base + SizeInt(y) * rowLen;
      for k := 0 to rowLen - 1 do begin
        if pos >= len then Break;
        { pos = rowStart + k }
        if k >= bpb then ch := CH_PAD
        else if part = 1 then ch := CH_MASK
        else if step > 1 then ch := k mod step
        else ch := 0;
        if k >= step then c[1] := At(pos - step) else c[1] := NONE;
        if y > 0 then begin
          c[2] := At(pos - rowLen);
          if k >= step then c[3] := At(pos - rowLen - step) else c[3] := NONE;
          if k + step < bpb then c[4] := At(pos - rowLen + step) else c[4] := NONE;
        end else begin c[2] := NONE; c[3] := NONE; c[4] := NONE; end;
        c[5] := PrevAt(pos);
        if (c[1] <> NONE) and (c[2] <> NONE) and (c[3] <> NONE) then
          c[6] := Clip(c[1] + c[2] - c[3])
        else if c[1] <> NONE then c[6] := c[1] else c[6] := c[2];
        { the channel before, in the same pixel, and how it changed from the left }
        if (step > 1) and (ch > 0) and (ch < step) and (k >= step) then begin
          c[8] := Clip(At(pos - 1) - At(pos - 1 - step) + 128);
          c[7] := Clip(c[1] + c[8] - 128);
        end else if (step > 1) and (ch > 0) and (ch < step) then begin
          c[8] := 512; c[7] := At(pos - 1);
        end else begin c[7] := NONE; c[8] := NONE; end;
        c[0] := ch;
        if cd.encoding then v := buf[pos] else v := 0;
        buf[pos] := m.Code(cd, v, c);
        Inc(pos);
      end;
      if pos >= len then Break;
    end;
    base := base + SizeInt(rows) * rowLen;
    if pos >= len then Break;
  end;
  { anything past the rows }
  while pos < len do begin
    c[0] := CH_TRAIL; c[1] := At(pos - 1);
    for width := 2 to 8 do c[width] := NONE;
    if cd.encoding then v := buf[pos] else v := 0;
    buf[pos] := m.Code(cd, v, c);
    Inc(pos);
  end;
  data := buf;
end;

end.
