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
    t: array[0..10] of TCounters;
    nt: Integer;             { 9, or 11 with the scaled context (ANI) }
    mx: TMixer;
    apm: TApm;
    mm: TMatchModel;
  public
    constructor Create(tableBits: Integer; scaled: Boolean = False);
    { a byte, from its context: c[0] a channel or mode (0-7), c[1..8]
      values (256: none) whose roles are paiadib's: left, up, up-left,
      up-right, the previous frame, a prediction, and two more together;
      with `scaled`, c[9]: the same place in a smaller bitmap of the same
      frame (ANI's sizes of one cursor) }
    function Code(cd: TCoder; v: Integer; const c: array of Integer): Integer;
  end;

{ The DIBs of the ANI at the start of d, if it is one. }
function FindDibs(const d: TBytes): TDibs;

{ Codes a DIB's pixel rows (decoding: fills `data`, `len` bytes); prev: the
  previous frame of the same shape, or nil. }
const
  TRUE_CONTEXTS = 29;
  LMS_INPUTS = 12;

type
  { The pixels of a true-colour bitmap (24 or 32 bits): many contexts on
    the neighbours, the other channels, the frame before and a smaller
    size of the same frame, mixed, then refined twice }
  TTrueModel = class
  private
    t: array of TCounters;
    mx: TMixer;
    apm1, apm2: TApm;
  public
    { an adaptive linear predictor a channel, in integers (16 fraction
      bits): the same everywhere }
    lw: array[0..3, 0..LMS_INPUTS - 1] of Int64;
    constructor Create(tableBits: Integer);
    { v when encoding; h: the contexts, hashed; sel: the mixer's weight
      set; a1, a2: the refining maps' contexts }
    function Code(cd: TCoder; v: Integer; const h: array of QWord; sel, a1, a2: Integer): Integer;
  end;


procedure CodeDib(cd: TCoder; m: TDibModel; const dib: TDib; var data: TBytes;
                  len: SizeInt; const prev: TBytes; const small: TBytes; sw, sh: Integer;
                  tm: TTrueModel = nil);

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
var cnt, k, w, h, bpp, colors: Integer; e, pix, need: SizeInt;
    io, isz, hs: Int64;   { 32-bit fields: Int64, so that none wraps in i386's SizeInt }
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
var last: Boolean; sz: Int64;   { a chunk's 32-bit size: in i386's SizeInt, 4 GB-ish wraps negative }
begin
  while q + 8 <= stop do begin
    sz := Le32(d, q + 4);
    { a chunk past its list's end, but within the file (a list whose size
      is a few bytes short, as in some cursors): taken, and the last one }
    last := q + 8 + sz > stop;
    if last and (q + 8 + sz > Length(d)) then Exit;
    if (d[q] = Ord('L')) and (d[q + 1] = Ord('I')) and (d[q + 2] = Ord('S')) and (d[q + 3] = Ord('T')) then begin
      if (depth < 4) and (sz >= 4) then Walk(d, q + 12, q + 8 + sz, r, n, depth + 1);
    end else if (d[q] = Ord('i')) and (d[q + 1] = Ord('c')) and (d[q + 2] = Ord('o')) and (d[q + 3] = Ord('n')) then
      AddIcon(d, q + 8, sz, r, n);
    if last then Exit;
    q := q + 8 + sz + (sz and 1);
  end;
end;

function FindDibs(const d: TBytes): TDibs;
var n: Integer; stop: Int64;
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

constructor TDibModel.Create(tableBits: Integer; scaled: Boolean = False);
var i: Integer;
begin
  inherited Create;
  if scaled then nt := 11 else nt := 9;
  for i := 0 to nt - 1 do t[i].Init(tableBits, 255);
  if scaled then mx.Init(nt + 2, 8 * 8 * 2 * 2, 1, 11)
  else mx.Init(nt + 2, 8 * 8 * 2, 1, 11);
  apm.Init(8 * 256, 7);
  mm.Init(20);
end;

{ c: ch, L, U, UL, UR, P, gradient, cross-channel prediction, C0 delta }
function TDibModel.Code(cd: TCoder; v: Integer; const c: array of Integer): Integer;
var b, bit, node, sub, j, pm, pa, e, ch, sc, mctx: Integer; base: array[0..10] of QWord;
    slot: array[0..10] of SizeInt;
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
  sc := 0;
  if nt > 9 then begin
    if High(c) >= 9 then sc := c[9] else sc := 256;
    base[9] := Hash(ch * 512 + sc, 9);
    base[10] := Hash(Hash(ch * 512 + sc, c[6]), 10);
  end;
  e := mm.Expected(0);
  FillChar(slot, SizeOf(slot), 0);
  node := 1; sub := 1;
  for b := 7 downto 0 do begin
    if (b = 7) or (b = 3) then begin
      for j := 0 to nt - 1 do slot[j] := (Hash(base[j], node) shl 4) and t[j].mask;
      sub := 1;
    end;
    for j := 0 to nt - 1 do mx.Add(Stretch(t[j].P12(slot[j] + sub)));
    mx.Add(mm.Input(e, 8, node, b));
    mx.Add(256);
    mctx := ((ch and 7) * 8 + (7 - b)) * 2 + Ord(mm.len >= 16);
    if nt > 9 then mctx := mctx * 2 + Ord(sc <> 256);
    pm := mx.Mix(mctx);
    pa := apm.Refine(pm, (ch and 7) * 256 + (node and 255));
    bit := cd.Code((v shr b) and 1, (pm + 3 * pa) div 4);
    for j := 0 to nt - 1 do t[j].Update(slot[j] + sub, bit);
    mx.Update(bit);
    apm.Update(bit);
    mm.Learn(bit);
    node := node * 2 + bit;
    sub := sub * 2 + bit;
  end;
  Result := node and 255;
  mm.Update(Result);
end;

{ ---------------- the true-colour model ---------------- }

constructor TTrueModel.Create(tableBits: Integer);
var i, j: Integer;
begin
  inherited Create;
  for i := 0 to 3 do
    for j := 0 to LMS_INPUTS - 1 do lw[i][j] := 0;
  for i := 0 to 3 do lw[i][0] := 65536;    { at first: the left neighbour }
  SetLength(t, TRUE_CONTEXTS);
  for i := 0 to High(t) do t[i].Init(tableBits, 1023);
  mx.Init(TRUE_CONTEXTS + 1, 4096, 1, 12);
  apm1.Init(1024 * 256, 7);
  apm2.Init(1024 * 256, 7);
end;

function TTrueModel.Code(cd: TCoder; v: Integer; const h: array of QWord; sel, a1, a2: Integer): Integer;
var b, bit, node, sub, j, pm, p1, p2: Integer; slot: array[0..TRUE_CONTEXTS - 1] of SizeInt;
begin
  FillChar(slot, SizeOf(slot), 0);
  node := 1; sub := 1;
  for b := 7 downto 0 do begin
    if (b = 7) or (b = 3) then begin
      for j := 0 to TRUE_CONTEXTS - 1 do slot[j] := (Hash(h[j], node) shl 4) and t[j].mask;
      sub := 1;
    end;
    for j := 0 to TRUE_CONTEXTS - 1 do mx.Add(Stretch(t[j].P12(slot[j] + sub)));
    mx.Add(256);
    pm := mx.Mix(((sel and 511) * 8) + (7 - b));
    p1 := apm1.Refine(pm, (a1 and 1023) * 256 + (node and 255));
    p2 := apm2.Refine(pm, (a2 and 1023) * 256 + (node and 255));
    bit := cd.Code((v shr b) and 1, (2 * pm + p1 + p2) div 4);
    for j := 0 to TRUE_CONTEXTS - 1 do t[j].Update(slot[j] + sub, bit);
    mx.Update(bit);
    apm1.Update(bit);
    apm2.Update(bit);
    node := node * 2 + bit;
    sub := sub * 2 + bit;
  end;
  Result := node and 255;
end;

{ ---------------- the walk ---------------- }

const
  NONE = 256;
  CH_PAD = 6;
  CH_MASK = 5;
  CH_TRAIL = 7;

{ ---------------- the true-colour walk ---------------- }

function Clip8(x: Integer): Integer; inline;
begin
  if x < 0 then Result := 0 else if x > 255 then Result := 255 else Result := x;
end;

{ the colour bitmap of a 24- or 32-bit DIB, pixel by pixel: alpha first,
  then blue, green, red, each with its neighbours, the channels before it
  in the pixel, the frame before and a smaller size of the frame }
procedure TrueRows(cd: TCoder; m: TDibModel; tm: TTrueModel; const dib: TDib; var buf: TBytes;
                   len: SizeInt; const prev, small: TBytes; sw, sh: Integer);
const ORDER32: array[0..3] of Integer = (3, 0, 1, 2);
var rowLen, rowStart, p, si, sRow: SizeInt; x, y, oi, ch, step, w, hgt, k, bpb, v,
    W_, N_, NW, NE, WW, NN, P_, S_, grad, grad2, avg, ac, pc, pc2, curPc, curPc2,
    crossW, crossN, a, sel, sx, sy, PW, PN, PNW, PNE, mt, tpred, tpred2, lms, err, j: Integer;
    lx: array[0..LMS_INPUTS - 1] of Integer; acc, norm: Int64; h: array[0..TRUE_CONTEXTS - 1] of QWord;
    c: array[0..9] of Integer;
  function Px(xx, yy, cc: Integer): Integer; inline;
  begin
    if (xx < 0) or (yy < 0) or (xx >= w) then Result := 256
    else Result := buf[SizeInt(yy) * rowLen + SizeInt(xx) * step + cc];
  end;
  { the frame before, at a neighbour's place }
  function Pv(xx, yy, cc: Integer): Integer; inline;
  var q: SizeInt;
  begin
    if (prev = nil) or (xx < 0) or (yy < 0) or (xx >= w) then Exit(256);
    q := SizeInt(yy) * rowLen + SizeInt(xx) * step + cc;
    if q < Length(prev) then Result := prev[q] else Result := 256;
  end;
  function Hc(a1, a2: QWord; kk: Integer): QWord; inline;
  begin
    Result := Hash(Hash(QWord(ch) * 1024 + a1, a2), kk);
  end;
begin
  step := dib.bpp div 8;
  w := dib.width; hgt := dib.height;
  rowLen := Stride(w, dib.bpp);
  bpb := w * step;
  sRow := Stride(sw, dib.bpp);
  for y := 0 to hgt - 1 do begin
    rowStart := SizeInt(y) * rowLen;
    for x := 0 to w - 1 do
      for oi := 0 to step - 1 do begin
        if step = 4 then ch := ORDER32[oi] else ch := oi;
        p := rowStart + SizeInt(x) * step + ch;
        if p >= len then Continue;
        W_ := Px(x - 1, y, ch); N_ := Px(x, y - 1, ch);
        NW := Px(x - 1, y - 1, ch); NE := Px(x + 1, y - 1, ch);
        WW := Px(x - 2, y, ch); NN := Px(x, y - 2, ch);
        if (prev <> nil) and (p < Length(prev)) then P_ := prev[p] else P_ := 256;
        S_ := 256;
        if (small <> nil) and (sw > 0) and (sh > 0) then begin
          sx := x * sw div w; sy := y * sh div hgt;
          si := SizeInt(sy) * sRow + SizeInt(sx) * step + ch;
          if si < Length(small) then S_ := small[si];
        end;
        if (W_ <> 256) and (N_ <> 256) and (NW <> 256) then grad := Clip8(W_ + N_ - NW)
        else if W_ <> 256 then grad := W_ else if N_ <> 256 then grad := N_ else grad := 256;
        if (W_ <> 256) and (N_ <> 256) and (NE <> 256) then grad2 := Clip8(W_ + NE - N_) else grad2 := grad;
        if (W_ <> 256) and (N_ <> 256) then avg := (W_ + N_) div 2 else avg := grad;
        ac := 3;
        if (step = 4) and (ch <> 3) and (rowStart + SizeInt(x) * step + 3 < len) then begin
          a := buf[rowStart + SizeInt(x) * step + 3];
          if a = 0 then ac := 0 else if a = 255 then ac := 1 else ac := 2;
        end;
        pc := -1; pc2 := -1;
        if ch = 1 then pc := 0
        else if ch = 2 then begin pc := 1; pc2 := 0; end;
        crossW := 256; crossN := 256; curPc := 256; curPc2 := 256;
        if pc >= 0 then begin
          curPc := buf[rowStart + SizeInt(x) * step + pc];
          if W_ <> 256 then crossW := Clip8(W_ + curPc - Px(x - 1, y, pc));
          if N_ <> 256 then crossN := Clip8(N_ + curPc - Px(x, y - 1, pc));
        end;
        if pc2 >= 0 then curPc2 := buf[rowStart + SizeInt(x) * step + pc2];
        h[0] := Hc(ac, 0, 0);
        h[1] := Hc(W_, ac, 1);
        h[2] := Hc(N_, ac, 2);
        h[3] := Hc(W_ * 512 + N_, ac, 3);
        h[4] := Hc(NW * 512 + NE, N_, 4);
        h[5] := Hc(grad, ac, 5);
        h[6] := Hc(grad2, grad shr 3, 6);
        if Abs(W_ - N_) > 255 then v := 255 else v := Abs(W_ - N_);
        h[7] := Hc(avg, v shr 3, 7);
        h[8] := Hc(P_, ac, 8);
        h[9] := Hc(P_ * 512 + W_, 0, 9);
        h[10] := Hc(S_, ac, 10);
        h[11] := Hc(S_ * 512 + grad, 0, 11);
        h[12] := Hc(crossW, ac, 12);
        h[13] := Hc(crossN, crossW shr 2, 13);
        h[14] := Hc(curPc * 512 + curPc2, 0, 14);
        h[15] := Hc(WW * 512 + NN, W_ shr 2, 15);
        h[16] := Hc((W_ shr 2) * 4096 + (NW shr 2) * 64 + (N_ shr 2), 0, 16);
        h[17] := Hc((P_ shr 2) * 64 + (grad shr 2), ac, 17);
        { did the neighbours stay as they were in the frame before? }
        PW := Pv(x - 1, y, ch); PN := Pv(x, y - 1, ch); PNW := Pv(x - 1, y - 1, ch); PNE := Pv(x + 1, y - 1, ch);
        mt := 0;
        if P_ <> 256 then
          mt := 16 + Ord((W_ <> 256) and (W_ = PW)) + 2 * Ord((N_ <> 256) and (N_ = PN))
                + 4 * Ord((NW <> 256) and (NW = PNW)) + 8 * Ord((NE <> 256) and (NE = PNE));
        if (P_ <> 256) and (W_ <> 256) and (PW <> 256) then tpred := Clip8(P_ + W_ - PW) else tpred := P_;
        h[18] := Hc(P_, mt, 18);
        h[19] := Hc(tpred, mt and 3, 19);
        h[20] := Hc(P_ * 512 + grad, mt and 3, 20);
        h[21] := Hc(crossW * 512 + P_, mt and 1, 21);
        { the frame before, moved as the neighbours moved: an average of the
          left and upper neighbours' changes, and coarser views }
        if (P_ <> 256) and (W_ <> 256) and (PW <> 256) and (N_ <> 256) and (PN <> 256) then
          tpred2 := Clip8(P_ + ((W_ - PW) + (N_ - PN)) div 2)
        else tpred2 := tpred;
        h[22] := Hc(tpred2, ac, 22);
        h[23] := Hc(tpred2 shr 2, (tpred shr 2) * 64 + (grad shr 2), 23);
        h[24] := Hc(tpred shr 1, crossW shr 3, 24);
        h[25] := Hc(tpred2 shr 3, mt, 25);
        { the linear predictor: its inputs, a missing one as the left one (or 128) }
        lx[0] := W_; lx[1] := N_; lx[2] := NW; lx[3] := NE; lx[4] := WW; lx[5] := NN;
        lx[6] := P_; lx[7] := PW; lx[8] := PN; lx[9] := crossW; lx[10] := S_; lx[11] := tpred2;
        for j := 0 to LMS_INPUTS - 1 do
          if lx[j] = 256 then begin
            if W_ <> 256 then lx[j] := W_ else if N_ <> 256 then lx[j] := N_ else lx[j] := 128;
          end;
        acc := 0;
        for j := 0 to LMS_INPUTS - 1 do acc := acc + tm.lw[ch][j] * lx[j];
        lms := Clip8(Integer(SarInt64(acc, 16)));
        h[26] := Hc(lms, ac, 26);
        h[27] := Hc(lms shr 2, (grad shr 3) * 32 + (tpred2 shr 3), 27);
        h[28] := Hc(lms * 512 + P_, mt and 3, 28);
        sel := (ch * 32 + ac * 8 + Ord(S_ <> 256) * 4 + Ord(P_ <> 256) * 2 + Ord(pc >= 0)) * 4
               + (mt and 3);
        if mt = 31 then sel := 128 * 4 + ch * 8 + ac;
        if cd.encoding then v := buf[p] else v := 0;
        if mt = 31 then a := ch * 256 + (P_ and 255) else a := ch * 256 + lms;
        buf[p] := tm.Code(cd, v, h, sel, a, ch * 256 + (crossW and 255));
        { NLMS: weights move along the error, scaled by the inputs' energy }
        err := buf[p] - lms;
        norm := 1;
        for j := 0 to LMS_INPUTS - 1 do norm := norm + Int64(lx[j]) * lx[j];
        for j := 0 to LMS_INPUTS - 1 do
          tm.lw[ch][j] := tm.lw[ch][j] + (Int64(err) * lx[j] * 6144) div norm;
      end;
    for k := bpb to rowLen - 1 do begin
      p := rowStart + k;
      if p >= len then Break;
      c[0] := CH_PAD;
      if p > 0 then c[1] := buf[p - 1] else c[1] := NONE;
      for v := 2 to 9 do c[v] := NONE;
      if cd.encoding then v := buf[p] else v := 0;
      buf[p] := m.Code(cd, v, c);
    end;
  end;
end;

procedure CodeDib(cd: TCoder; m: TDibModel; const dib: TDib; var data: TBytes;
                  len: SizeInt; const prev: TBytes; const small: TBytes; sw, sh: Integer;
                  tm: TTrueModel);
var buf: TBytes; pos, rowLen, rowStart, base, si, sRow: SizeInt; y, k, step, ch, v, rows, sx, sy: Integer;
    c: array[0..9] of Integer; part, width, bpb: Integer;
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
  if (tm <> nil) and ((dib.bpp = 24) or (dib.bpp = 32)) then begin
    TrueRows(cd, m, tm, dib, buf, len, prev, small, sw, sh);
    base := SizeInt(dib.height) * Stride(dib.width, dib.bpp);
    pos := base;
    if pos > len then pos := len;
  end;
  for part := 0 to 1 do begin
    if (part = 0) and (tm <> nil) and ((dib.bpp = 24) or (dib.bpp = 32)) then Continue;
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
        { the same place in a smaller bitmap of the same frame }
        c[9] := NONE;
        if (part = 0) and (small <> nil) and (step >= 1) and (dib.bpp >= 8) and (k < bpb) then begin
          sx := (k div step) * sw div dib.width;
          sy := y * sh div dib.height;
          sRow := Stride(sw, dib.bpp);
          si := SizeInt(sy) * sRow + SizeInt(sx) * step + (k mod step);
          if (si >= 0) and (si < Length(small)) then c[9] := small[si];
        end;
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
    for width := 2 to 9 do c[width] := NONE;
    if cd.encoding then v := buf[pos] else v := 0;
    buf[pos] := m.Code(cd, v, c);
    Inc(pos);
  end;
  data := buf;
end;

end.
