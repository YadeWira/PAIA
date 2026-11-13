{ FLI and FLC (Autodesk Animator): finding the pixel chunks of a file, and
  coding them.

  A FLIC's pixel chunks are simple run-length and delta codes. Rather than
  decode them and rebuild them (as for GIF's LZW), each chunk's bytes are
  coded in their own order, field by field, the coder knowing at every byte
  what it is: a field of the structure (a packet count, a skip, a line
  count) goes to a token model, a pixel to a pixel model that sees the image
  as it is being built (its neighbours, and what was there before the chunk
  changed it). So any chunk comes back exactly, whatever the encoder did:
  there is nothing to guess, and nothing to check but the whole file.

  The chunks taken (FLI, FLC, and the 15-, 16- and 24-bit FLCs of magic
  0xAF12 and 0xAF44, whose pixels are 2 or 3 bytes):
     4  COLOR_256, 11 COLOR_64: palette changes
     7  DELTA_FLC (SS2): word-oriented delta; on deeper FLCs, as 27
    12  DELTA_FLI (LC): byte-oriented delta
    13  BLACK
    15  BYTE_RUN: the whole frame, run-length coded
    16  COPY (FLI_COPY): the whole frame, as it is
    18  PSTAMP: the postage stamp (a small image of its own), in the
        prefix chunk 0xF100 or a frame
    25  DTA_BRUN, 26 DTA_COPY, 27 DTA_LC: as 15, 16 and 7, pixels of 2 or
        3 bytes
    0x5344 ("DS"): sound, 16-bit samples, some FLIs carry one per frame
  Every other byte of the file (headers, other chunks) stays with the
  plain bytes. }
unit paiafli;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiafli: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiafli: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith;

const
  CT_DELTA_FLC = 7;
  CT_DELTA_FLI = 12;
  CT_BLACK = 13;
  CT_BYTE_RUN = 15;
  CT_COPY = 16;
  CT_COLOR_256 = 4;
  CT_COLOR_64 = 11;
  CT_PSTAMP = 18;
  CT_DTA_BRUN = 25;
  CT_DTA_COPY = 26;
  CT_DTA_LC = 27;
  CT_SOUND = $5344;

type
  TFliChunk = record
    dataStart, dataEnd: SizeInt;   { the chunk's data, after its 6-byte header }
    ctype: Integer;
    width, height: Integer;
    bpp: Integer;                  { bytes a pixel: 1, 2 or 3 }
    stream: Integer;               { which FLIC of the file }
  end;
  TFliChunks = array of TFliChunk;

  { The models, shared by all the chunks of a file. }
  TFliModel = class
  private
    { tokens }
    tt: array[0..2] of TCounters;
    tmx: TMixer;
    { pixels }
    pt: array[0..8] of TCounters;
    pmx: TMixer;
    papm: TApm;
    mm: TMatchModel;
    function Token(cd: TCoder; v, bits, kind, c1, c2: Integer): Integer;
    function Pixel(cd: TCoder; v: Integer; const ctx: array of Integer; mode: Integer): Integer;
  public
    constructor Create(tableBits: Integer);
  end;

  { One FLIC's image, as the chunks build it. }
  TFliImage = class
    w, h, bpp: Integer;
    img: TBytes;                   { w * h * bpp bytes }
    pal: array[0..767] of Byte;    { the palette, as its chunks change it }
    s1, s2: Integer;               { the sound's last two samples }
    constructor Create(aw, ah, abpp: Integer);
  end;

{ The pixel chunks of the FLIC at the start of d, if it is one. }
function FindFliChunks(const d: TBytes): TFliChunks;

{ Codes a chunk's data (decoding: fills it, `len` bytes) and applies it to
  the image. }
procedure CodeChunk(cd: TCoder; m: TFliModel; im: TFliImage; ctype: Integer;
                    var data: TBytes; len: SizeInt);

{ The number of symbols a file's chunks will code, for sizing the tables. }
function FliSymbols(const c: TFliChunks): QWord;

implementation

const
  { token kinds }
  K_BRUN_CNT = 1; K_BRUN_LINE = 2;
  K_LC_Y0 = 3; K_LC_N = 4; K_LC_PK = 5; K_LC_SKIP = 6; K_LC_CNT = 7;
  K_SS2_LINES = 8; K_SS2_OP = 9; K_SS2_SKIP = 10; K_SS2_CNT = 11;
  K_TRAIL = 12;
  K_PAL_N = 13; K_PAL_SKIP = 14; K_PAL_CNT = 15; K_PAL_V = 16; K_STAMP = 17; K_SND = 18;
  K_N_CNT = 19; K_N_LINES = 20; K_N_OP = 21; K_N_SKIP = 22;
  { pixel modes }
  M_LIT = 0; M_REP = 1; M_REP2 = 2; M_COPY = 3;
  NONE = 256;

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

{ ---------------- finding the chunks ---------------- }

function FindFliChunks(const d: TBytes): TFliChunks;
var magic, w, h, depth, bpp, n, j, ft: Integer; q, r, len, fend: SizeInt; ct: Integer; take: Boolean;
    size, ss: Int64;   { 32-bit sizes: Int64, so that q + size never wraps on i386 }
    c: TFliChunk;
begin
  Result := nil; n := 0;
  len := Length(d);
  if len < 128 then Exit;
  magic := Le16(d, 4);
  if (magic <> $AF11) and (magic <> $AF12) and (magic <> $AF44) then Exit;
  w := Le16(d, 8); h := Le16(d, 10); depth := Le16(d, 12);
  if magic = $AF11 then depth := 8;
  case depth of
    0, 8: bpp := 1;
    15, 16: bpp := 2;
    24: bpp := 3;
  else Exit;
  end;
  if (w < 1) or (h < 1) then Exit;
  if SizeInt(w) * h * bpp > SizeInt(1) shl 26 then Exit;
  q := 128;
  while q + 6 <= len do begin
    size := Le32(d, q);
    if (size < 6) or (q + size > len) then Break;
    ft := Le16(d, q + 4);
    if (ft = $F1FA) or (ft = $F100) then begin
      if size < 16 then Break;
      fend := q + size;
      r := q + 16;
      for j := 1 to Le16(d, q + 6) do begin
        if r + 6 > fend then Break;
        ss := Le32(d, r);
        if (ss < 6) or (r + ss > fend) then Break;
        ct := Le16(d, r + 4);
        if ft = $F100 then take := ct = CT_PSTAMP
        else if (ct = CT_PSTAMP) or (ct = CT_SOUND) or (ct = CT_COLOR_256) or (ct = CT_COLOR_64)
                or (ct = CT_BLACK) or (ct = CT_DELTA_FLC) or (ct = CT_BYTE_RUN) or (ct = CT_COPY) then take := True
        else if bpp = 1 then take := ct = CT_DELTA_FLI
        else take := (ct = CT_DTA_BRUN) or (ct = CT_DTA_COPY) or (ct = CT_DTA_LC);
        if take then begin
          c.dataStart := r + 6; c.dataEnd := r + ss;
          c.ctype := ct; c.width := w; c.height := h; c.bpp := bpp; c.stream := 0;
          if n >= Length(Result) then SetLength(Result, n * 2 + 16);
          Result[n] := c; Inc(n);
        end;
        r := r + ss;
      end;
    end;
    q := q + size;
  end;
  SetLength(Result, n);
end;

function FliSymbols(const c: TFliChunks): QWord;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(c) do Result := Result + QWord(c[i].dataEnd - c[i].dataStart);
end;

{ ---------------- the models ---------------- }

constructor TFliModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(tt) do tt[i].Init(tableBits - 2, 60);
  tmx.Init(Length(tt) + 2, 32 * 16, 1, 11);
  for i := 0 to High(pt) do pt[i].Init(tableBits, 255);
  pmx.Init(Length(pt) + 2, 8 * 16 * 2, 1, 11);
  papm.Init(257 * 256, 6);
  mm.Init(20);
end;

{ A value of `bits` bits, from the top, its contexts hashed with the kind
  and the bits so far. }
function TFliModel.Token(cd: TCoder; v, bits, kind, c1, c2: Integer): Integer;
var b, bit, node, j, p, e: Integer; idx: array[0..2] of SizeInt; h: array[0..2] of QWord;
begin
  { the match's expected value: one byte, or two (low first) }
  e := mm.Expected(0);
  if (bits = 16) and (e >= 0) then begin
    if mm.Expected(1) >= 0 then e := e or (mm.Expected(1) shl 8) else e := -1;
  end;
  h[0] := Hash(kind, 0);
  h[1] := Hash(kind * 65536 + c1, 1);
  h[2] := Hash(Hash(kind * 65536 + c1, c2), 2);
  node := 1;
  for b := bits - 1 downto 0 do begin
    for j := 0 to 2 do begin
      idx[j] := Hash(h[j], node) and tt[j].mask;
      tmx.Add(Stretch(tt[j].P12(idx[j])));
    end;
    tmx.Add(mm.Input(e, bits, node, b));
    tmx.Add(256);
    p := tmx.Mix((kind and 31) * 16 + (bits - 1 - b) and 15);
    bit := cd.Code((v shr b) and 1, p);
    for j := 0 to 2 do tt[j].Update(idx[j], bit);
    tmx.Update(bit);
    mm.Learn(bit);
    node := node * 2 + bit;
  end;
  Result := node - (1 shl bits);
  mm.Update(Result and 255);
  if bits = 16 then mm.Update(Result shr 8);
end;

{ ctx: L, U, UL, UR, LL, P (before the chunk), PR, PD }
function TFliModel.Pixel(cd: TCoder; v: Integer; const ctx: array of Integer; mode: Integer): Integer;
var b, bit, node, sub, j, pm, pa, sel, e: Integer; base: array[0..8] of QWord;
    slot: array[0..8] of SizeInt; L, U, UL, UR, LL, P, PR, PD: Integer;
begin
  L := ctx[0]; U := ctx[1]; UL := ctx[2]; UR := ctx[3]; LL := ctx[4];
  P := ctx[5]; PR := ctx[6]; PD := ctx[7];
  base[0] := mode;
  base[1] := Hash(L, 1 + mode * 16);
  base[2] := Hash(U, 2);
  base[3] := Hash(L * 512 + U, 3);
  base[4] := Hash(Hash(L * 512 + U, UL * 512 + UR), 4);
  base[5] := Hash(P, 5 + mode * 16);
  base[6] := Hash(P * 512 + L, 6);
  base[7] := Hash(Hash(P * 512 + U, PR * 512 + PD), 7);
  base[8] := Hash(Hash(L * 512 + LL, U), 8);
  e := mm.Expected(0);
  sel := Ord(L = U) + 2 * Ord(P = L) + 4 * Ord(P = U) + 8 * Ord(mode = M_LIT)
       + 16 * Ord(mm.len >= 16);
  FillChar(slot, SizeOf(slot), 0);
  node := 1; sub := 1;
  for b := 7 downto 0 do begin
    if (b = 7) or (b = 3) then begin
      for j := 0 to High(pt) do slot[j] := (Hash(base[j], node) shl 4) and pt[j].mask;
      sub := 1;
    end;
    for j := 0 to High(pt) do pmx.Add(Stretch(pt[j].P12(slot[j] + sub)));
    pmx.Add(mm.Input(e, 8, node, b));
    pmx.Add(256);
    pm := pmx.Mix((7 - b) * 32 + sel);
    pa := papm.Refine(pm, (L * 256) + (node and 255));
    bit := cd.Code((v shr b) and 1, (pm + 3 * pa) div 4);
    for j := 0 to High(pt) do pt[j].Update(slot[j] + sub, bit);
    pmx.Update(bit);
    papm.Update(bit);
    mm.Learn(bit);
    node := node * 2 + bit;
    sub := sub * 2 + bit;
  end;
  Result := node and 255;
  mm.Update(Result);
end;

{ ---------------- the image ---------------- }

constructor TFliImage.Create(aw, ah, abpp: Integer);
begin
  inherited Create;
  w := aw; h := ah; bpp := abpp;
  img := nil;
  SetLength(img, SizeInt(w) * h * bpp);
  FillChar(pal, SizeOf(pal), 0);
  s1 := 0; s2 := 0;
end;

{ ---------------- the walk ---------------- }

{ a value as a context: clipped to a byte }
function Min2(x: Integer): Integer; inline;
begin
  if x > 255 then Result := 255 else if x < 0 then Result := 0 else Result := x;
end;

type
  TWalk = record
    cd: TCoder;
    m: TFliModel;
    im: TFliImage;
    old: TBytes;
    buf: TBytes;
    pos, len: SizeInt;
    function More(k: SizeInt): Boolean; inline;
    function TB(kind, c1, c2: Integer): Integer;
    function TBAt(p: SizeInt; kind, c1, c2: Integer): Integer;
    function TW(kind, c1, c2: Integer): Integer;
    function PX(x, y, mode: Integer): Integer;
    procedure Fill(x, y, n, v: Integer);
    { pixels of bpp bytes: byte b of pixel (x, y) }
    function PXN(x, y, b, mode: Integer): Integer;
    procedure FillN(x, y, n: Integer; const v: array of Integer);
  end;

function TWalk.More(k: SizeInt): Boolean; inline;
begin
  Result := pos + k <= len;
end;

function TWalk.TBAt(p: SizeInt; kind, c1, c2: Integer): Integer;
var v: Integer;
begin
  if cd.encoding then v := buf[p] else v := 0;
  Result := m.Token(cd, v, 8, kind, c1, c2);
  buf[p] := Result;
end;

function TWalk.TB(kind, c1, c2: Integer): Integer;
begin
  Result := TBAt(pos, kind, c1, c2);
  Inc(pos);
end;

function TWalk.TW(kind, c1, c2: Integer): Integer;
var v: Integer;
begin
  if cd.encoding then v := Le16(buf, pos) else v := 0;
  Result := m.Token(cd, v, 16, kind, c1, c2);
  buf[pos] := Result and 255; buf[pos + 1] := Result shr 8;
  Inc(pos, 2);
end;

function TWalk.PX(x, y, mode: Integer): Integer;
var ctx: array[0..7] of Integer; w, h, v: Integer; i: SizeInt; inside: Boolean;
begin
  w := im.w; h := im.h;
  inside := (x >= 0) and (y >= 0) and (x < w) and (y < h);
  if inside then begin
    i := SizeInt(y) * w + x;
    if x > 0 then ctx[0] := im.img[i - 1] else ctx[0] := NONE;
    if y > 0 then ctx[1] := im.img[i - w] else ctx[1] := NONE;
    if (y > 0) and (x > 0) then ctx[2] := im.img[i - w - 1] else ctx[2] := NONE;
    if (y > 0) and (x + 1 < w) then ctx[3] := im.img[i - w + 1] else ctx[3] := NONE;
    if x > 1 then ctx[4] := im.img[i - 2] else ctx[4] := NONE;
    ctx[5] := old[i];
    if x + 1 < w then ctx[6] := old[i + 1] else ctx[6] := NONE;
    if y + 1 < h then ctx[7] := old[i + w] else ctx[7] := NONE;
  end else begin
    i := 0;
    for v := 0 to 7 do ctx[v] := NONE;
  end;
  if cd.encoding then v := buf[pos] else v := 0;
  Result := m.Pixel(cd, v, ctx, mode);
  buf[pos] := Result;
  Inc(pos);
  if inside then im.img[i] := Result;
end;

procedure TWalk.Fill(x, y, n, v: Integer);
var k: Integer;
begin
  if (y < 0) or (y >= im.h) then Exit;
  for k := 0 to n - 1 do
    if (x + k >= 0) and (x + k < im.w) then im.img[SizeInt(y) * im.w + x + k] := v;
end;

function TWalk.PXN(x, y, b, mode: Integer): Integer;
var ctx: array[0..7] of Integer; w, h, v, n: Integer; i, row: SizeInt; inside: Boolean;
begin
  w := im.w; h := im.h; n := im.bpp;
  inside := (x >= 0) and (y >= 0) and (x < w) and (y < h);
  if inside then begin
    row := SizeInt(w) * n;
    i := (SizeInt(y) * w + x) * n + b;
    if x > 0 then ctx[0] := im.img[i - n] else ctx[0] := NONE;
    if y > 0 then ctx[1] := im.img[i - row] else ctx[1] := NONE;
    if (y > 0) and (x > 0) then ctx[2] := im.img[i - row - n] else ctx[2] := NONE;
    if (y > 0) and (x + 1 < w) then ctx[3] := im.img[i - row + n] else ctx[3] := NONE;
    { the pixel's byte below this one, else two to the left }
    if b > 0 then ctx[4] := im.img[i - 1]
    else if x > 1 then ctx[4] := im.img[i - 2 * n] else ctx[4] := NONE;
    ctx[5] := old[i];
    if x + 1 < w then ctx[6] := old[i + n] else ctx[6] := NONE;
    if y + 1 < h then ctx[7] := old[i + row] else ctx[7] := NONE;
  end else begin
    i := 0;
    for v := 0 to 7 do ctx[v] := NONE;
  end;
  if cd.encoding then v := buf[pos] else v := 0;
  Result := m.Pixel(cd, v, ctx, mode + 4 * (b + 1));
  buf[pos] := Result;
  Inc(pos);
  if inside then im.img[i] := Result;
end;

procedure TWalk.FillN(x, y, n: Integer; const v: array of Integer);
var k, b: Integer;
begin
  if (y < 0) or (y >= im.h) then Exit;
  for k := 0 to n - 1 do
    if (x + k >= 0) and (x + k < im.w) then
      for b := 0 to im.bpp - 1 do
        im.img[(SizeInt(y) * im.w + x + k) * im.bpp + b] := v[b];
end;

procedure WalkByteRun(var wk: TWalk);
var y, x, c, npk, last: Integer; p0: SizeInt;
begin
  for y := 0 to wk.im.h - 1 do begin
    if not wk.More(1) then Exit;
    p0 := wk.pos; Inc(wk.pos);          { the line's packet count: coded after its packets }
    x := 0; npk := 0; last := 0;
    while x < wk.im.w do begin
      if not wk.More(1) then Break;
      c := ShortInt(wk.TB(K_BRUN_CNT, Min2(wk.im.w - x), last));
      last := c and 255;
      Inc(npk);
      if c >= 0 then begin
        if not wk.More(1) then Break;
        wk.Fill(x, y, c, wk.PX(x, y, M_REP));
        x := x + c;
        if c = 0 then Inc(x);  { a zero run: nothing, but the line must end }
      end else begin
        c := -c;
        while (c > 0) and wk.More(1) do begin wk.PX(x, y, M_LIT); Inc(x); Dec(c); end;
        if c > 0 then Break;
      end;
    end;
    wk.TBAt(p0, K_BRUN_LINE, npk and 255, 0);
  end;
end;

procedure WalkDeltaFli(var wk: TWalk);
var y, n, line, npk, k, x, skip, c, lastPk, lastSkip, lastCnt, v: Integer;
begin
  if not wk.More(4) then Exit;
  y := wk.TW(K_LC_Y0, 0, 0);
  n := wk.TW(K_LC_N, 0, 0);
  lastPk := 0; lastSkip := 0; lastCnt := 0;
  for line := 1 to n do begin
    if not wk.More(1) then Exit;
    npk := wk.TB(K_LC_PK, lastPk, 0);
    lastPk := npk;
    x := 0;
    for k := 1 to npk do begin
      if not wk.More(2) then Exit;
      skip := wk.TB(K_LC_SKIP, lastSkip, Ord(k = 1));
      lastSkip := skip;
      x := x + skip;
      c := ShortInt(wk.TB(K_LC_CNT, lastCnt, Min2(skip)));
      lastCnt := c and 255;
      if c > 0 then begin
        while (c > 0) and wk.More(1) do begin wk.PX(x, y, M_LIT); Inc(x); Dec(c); end;
        if c > 0 then Exit;
      end else if c < 0 then begin
        if not wk.More(1) then Exit;
        v := wk.PX(x, y, M_REP);
        wk.Fill(x, y, -c, v);
        x := x - c;
      end;
    end;
    Inc(y);
  end;
end;

procedure WalkDeltaFlc(var wk: TWalk);
var nl, lines, y, op, lastOp, npk, k, x, skip, c, a, b, j, lastSkip, lastCnt: Integer;
begin
  if not wk.More(2) then Exit;
  nl := wk.TW(K_SS2_LINES, 0, 0);
  lines := 0; y := 0; lastOp := 0; lastSkip := 0; lastCnt := 0;
  while lines < nl do begin
    if not wk.More(2) then Exit;
    op := wk.TW(K_SS2_OP, lastOp shr 14, Min2(lastOp and $FF));
    lastOp := op;
    case op and $C000 of
      $C000: y := y + (65536 - op);
      $8000: if (y >= 0) and (y < wk.im.h) then
               wk.im.img[SizeInt(y) * wk.im.w + wk.im.w - 1] := op and 255;
      $4000: Exit;     { undefined: what is left is trailing }
    else begin
      npk := op;
      x := 0;
      for k := 1 to npk do begin
        if not wk.More(2) then Exit;
        skip := wk.TB(K_SS2_SKIP, lastSkip, Ord(k = 1));
        lastSkip := skip;
        x := x + skip;
        c := ShortInt(wk.TB(K_SS2_CNT, lastCnt, Min2(skip)));
        lastCnt := c and 255;
        if c > 0 then begin
          while (c > 0) and wk.More(2) do begin
            wk.PX(x, y, M_LIT); wk.PX(x + 1, y, M_LIT); x := x + 2; Dec(c);
          end;
          if c > 0 then Exit;
        end else if c < 0 then begin
          if not wk.More(2) then Exit;
          a := wk.PX(x, y, M_REP); b := wk.PX(x + 1, y, M_REP2);
          for j := 1 to -c do begin
            wk.Fill(x, y, 1, a); wk.Fill(x + 1, y, 1, b); x := x + 2;
          end;
        end;
      end;
      Inc(y); Inc(lines);
    end;
    end;
  end;
end;

procedure WalkCopy(var wk: TWalk);
var x, y: Integer;
begin
  for y := 0 to wk.im.h - 1 do
    for x := 0 to wk.im.w - 1 do begin
      if not wk.More(1) then Exit;
      wk.PX(x, y, M_COPY);
    end;
end;

{ ---------------- palettes, stamps, sound, deeper pixels ---------------- }

{ COLOR_256 and COLOR_64: packets of (skip, count, count RGB triples); each
  value with the one it replaces as context }
procedure WalkPalette(var wk: TWalk);
var npk, k, skip, cnt, j, c, idx, v, prev: Integer;
begin
  if not wk.More(2) then Exit;
  npk := wk.TW(K_PAL_N, 0, 0);
  idx := 0; prev := 0;
  for k := 1 to npk do begin
    if not wk.More(2) then Exit;
    skip := wk.TB(K_PAL_SKIP, Ord(k = 1), 0);
    idx := idx + skip;
    cnt := wk.TB(K_PAL_CNT, Min2(idx), 0);
    if cnt = 0 then cnt := 256;
    for j := 1 to cnt do begin
      for c := 0 to 2 do begin
        if not wk.More(1) then Exit;
        if idx < 256 then v := wk.im.pal[idx * 3 + c] else v := 0;
        prev := wk.TB(K_PAL_V, v, c * 256 + prev);
        if idx < 256 then wk.im.pal[idx * 3 + c] := prev;
      end;
      Inc(idx);
    end;
  end;
end;

{ PSTAMP: height, width, translation flag, then a chunk of its own: a
  BYTE_RUN or COPY image of that size (or a translation table) }
procedure WalkStamp(var wk: TWalk);
var sh, sw, k, t: Integer; size: Int64; keepIm: TFliImage; keepOld: TBytes;
begin
  if not wk.More(6) then Exit;
  sh := wk.TW(K_STAMP, 0, 0); sw := wk.TW(K_STAMP, 1, 0); wk.TW(K_STAMP, 2, 0);
  if not wk.More(6) then Exit;
  size := 0;
  for k := 0 to 3 do size := size or (Int64(wk.TB(K_STAMP, 3 + k, 0)) shl (8 * k));
  t := wk.TW(K_STAMP, 7, 0);
  if ((t <> CT_BYTE_RUN) and (t <> CT_COPY)) or (sw < 1) or (sh < 1) or (SizeInt(sw) * sh > 1 shl 20) then Exit;
  keepIm := wk.im; keepOld := wk.old;
  wk.im := TFliImage.Create(sw, sh, 1);
  try
    wk.old := Copy(wk.im.img, 0, Length(wk.im.img));
    if t = CT_BYTE_RUN then WalkByteRun(wk) else WalkCopy(wk);
  finally
    wk.im.Free;
    wk.im := keepIm; wk.old := keepOld;
  end;
end;

{ sound: 16-bit samples; each as its difference from 2 s1 - s2 (modulo
  65536: exact for any value), the size of the last difference as context }
procedure WalkSound(var wk: TWalk);
var pred, v, r, s, bucket, last: Integer;
begin
  last := 0;
  while wk.More(2) do begin
    pred := 2 * wk.im.s1 - wk.im.s2;
    if pred > 32767 then pred := 32767 else if pred < -32768 then pred := -32768;
    if wk.cd.encoding then begin
      s := SmallInt(Le16(wk.buf, wk.pos));
      v := (s - pred) and $FFFF;
    end else v := 0;
    bucket := 0;
    while (bucket < 15) and ((last shr bucket) > 0) do Inc(bucket);
    r := wk.m.Token(wk.cd, v, 16, K_SND, bucket, 0);
    s := SmallInt((pred + r) and $FFFF);
    wk.buf[wk.pos] := s and 255; wk.buf[wk.pos + 1] := (s shr 8) and 255;
    Inc(wk.pos, 2);
    last := Abs(SmallInt(r));
    wk.im.s2 := wk.im.s1; wk.im.s1 := s;
  end;
end;

{ DTA_BRUN: BYTE_RUN of pixels of bpp bytes }
procedure WalkBrunN(var wk: TWalk);
var y, x, c, npk, last, b: Integer; p0: SizeInt; v: array[0..2] of Integer;
begin
  FillChar(v, SizeOf(v), 0);
  for y := 0 to wk.im.h - 1 do begin
    if not wk.More(1) then Exit;
    p0 := wk.pos; Inc(wk.pos);
    x := 0; npk := 0; last := 0;
    while x < wk.im.w do begin
      if not wk.More(1) then Break;
      c := ShortInt(wk.TB(K_N_CNT, Min2(wk.im.w - x), last));
      last := c and 255;
      Inc(npk);
      if c > 0 then begin
        if not wk.More(wk.im.bpp) then Break;
        for b := 0 to wk.im.bpp - 1 do v[b] := wk.PXN(x, y, b, M_REP);
        wk.FillN(x, y, c, v);
        x := x + c;
      end else if c < 0 then begin
        c := -c;
        while (c > 0) and wk.More(wk.im.bpp) do begin
          for b := 0 to wk.im.bpp - 1 do wk.PXN(x, y, b, M_LIT);
          Inc(x); Dec(c);
        end;
        if c > 0 then Break;
      end else
        Inc(x);
    end;
    wk.TBAt(p0, K_BRUN_LINE, npk and 255, 1);
  end;
end;

{ DTA_LC (and DELTA_FLC on deeper FLCs): lines; per line a word, negative
  to skip lines, else packets of (skip, count): a pixel repeated, or
  pixels }
procedure WalkDeltaN(var wk: TWalk);
var nl, lines, y, op, npk, k, x, skip, c, b, lastSkip, lastCnt: Integer; v: array[0..2] of Integer;
begin
  FillChar(v, SizeOf(v), 0);
  if not wk.More(2) then Exit;
  nl := wk.TW(K_N_LINES, 0, 0);
  lines := 0; y := 0; lastSkip := 0; lastCnt := 0;
  while lines < nl do begin
    if not wk.More(2) then Exit;
    op := SmallInt(wk.TW(K_N_OP, 0, 0));
    if op < 0 then begin y := y - op; Continue; end;
    npk := op; x := 0;
    for k := 1 to npk do begin
      if not wk.More(2) then Exit;
      skip := wk.TB(K_N_SKIP, lastSkip, Ord(k = 1));
      lastSkip := skip;
      x := x + skip;
      c := ShortInt(wk.TB(K_N_CNT, lastCnt, Min2(skip)));
      lastCnt := c and 255;
      if c < 0 then begin
        if not wk.More(wk.im.bpp) then Exit;
        for b := 0 to wk.im.bpp - 1 do v[b] := wk.PXN(x, y, b, M_REP);
        wk.FillN(x, y, -c, v);
        x := x - c;
      end else begin
        while (c > 0) and wk.More(wk.im.bpp) do begin
          for b := 0 to wk.im.bpp - 1 do wk.PXN(x, y, b, M_LIT);
          Inc(x); Dec(c);
        end;
        if c > 0 then Exit;
      end;
    end;
    Inc(y); Inc(lines);
  end;
end;

{ DTA_COPY (and COPY on deeper FLCs): the pixels, a 2-byte pad after each
  line of an odd width of 2-byte pixels }
procedure WalkCopyN(var wk: TWalk);
var x, y, b: Integer;
begin
  for y := 0 to wk.im.h - 1 do begin
    for x := 0 to wk.im.w - 1 do
      for b := 0 to wk.im.bpp - 1 do begin
        if not wk.More(1) then Exit;
        wk.PXN(x, y, b, M_COPY);
      end;
    if (wk.im.bpp = 2) and Odd(wk.im.w) then begin
      if not wk.More(2) then Exit;
      wk.TB(K_TRAIL, 0, 2); wk.TB(K_TRAIL, 0, 2);
    end;
  end;
end;

{ BYTE_RUN on deeper FLCs: runs of bytes along the line's w * bpp bytes }
procedure WalkByteRunBytes(var wk: TWalk);
var y, x, c, npk, last, n, v, k: Integer; p0: SizeInt;
begin
  n := wk.im.w * wk.im.bpp;
  for y := 0 to wk.im.h - 1 do begin
    if not wk.More(1) then Exit;
    p0 := wk.pos; Inc(wk.pos);
    x := 0; npk := 0; last := 0;
    while x < n do begin
      if not wk.More(1) then Break;
      c := ShortInt(wk.TB(K_BRUN_CNT, Min2(n - x), last));
      last := c and 255;
      Inc(npk);
      if c > 0 then begin
        if not wk.More(1) then Break;
        v := wk.PXN(x div wk.im.bpp, y, x mod wk.im.bpp, M_REP);
        for k := 1 to c - 1 do
          if x + k < n then wk.im.img[SizeInt(y) * n + x + k] := v;
        x := x + c;
      end else if c < 0 then begin
        c := -c;
        while (c > 0) and wk.More(1) do begin
          wk.PXN(x div wk.im.bpp, y, x mod wk.im.bpp, M_LIT); Inc(x); Dec(c);
        end;
        if c > 0 then Break;
      end else
        Inc(x);
    end;
    wk.TBAt(p0, K_BRUN_LINE, npk and 255, 2);
  end;
end;

procedure CodeChunk(cd: TCoder; m: TFliModel; im: TFliImage; ctype: Integer;
                    var data: TBytes; len: SizeInt);
var wk: TWalk; last: Integer;
begin
  wk.cd := cd; wk.m := m; wk.im := im;
  wk.old := Copy(im.img, 0, Length(im.img));
  if not cd.encoding then begin data := nil; SetLength(data, len); end;
  wk.buf := data; wk.pos := 0; wk.len := len;
  case ctype of
    CT_COLOR_256, CT_COLOR_64: WalkPalette(wk);
    CT_PSTAMP: WalkStamp(wk);
    CT_SOUND: WalkSound(wk);
    CT_BLACK: if Length(im.img) > 0 then FillChar(im.img[0], Length(im.img), 0);
  else
    if im.bpp = 1 then
      case ctype of
        CT_BYTE_RUN: WalkByteRun(wk);
        CT_DELTA_FLI: WalkDeltaFli(wk);
        CT_DELTA_FLC: WalkDeltaFlc(wk);
        CT_COPY: WalkCopy(wk);
      end
    else
      case ctype of
        CT_DTA_BRUN: WalkBrunN(wk);
        CT_DTA_LC, CT_DELTA_FLC: WalkDeltaN(wk);
        CT_DTA_COPY, CT_COPY: WalkCopyN(wk);
        CT_BYTE_RUN: WalkByteRunBytes(wk);
      end;
  end;
  { whatever the structure did not use }
  last := 0;
  while wk.pos < wk.len do last := wk.TB(K_TRAIL, last, 0);
  data := wk.buf;
end;

end.
