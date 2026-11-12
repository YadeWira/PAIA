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

  The chunks taken, of 8-bit FLICs:
     7  DELTA_FLC (SS2): word-oriented delta
    12  DELTA_FLI (LC): byte-oriented delta
    13  BLACK
    15  BYTE_RUN: the whole frame, run-length coded
    16  COPY (FLI_COPY): the whole frame, as it is
  Every other byte of the file (headers, palettes, stamps, other chunks)
  stays with the plain bytes. }
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

type
  TFliChunk = record
    dataStart, dataEnd: SizeInt;   { the chunk's data, after its 6-byte header }
    ctype: Integer;
    width, height: Integer;
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
    w, h: Integer;
    img: TBytes;
    constructor Create(aw, ah: Integer);
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
var magic, w, h, depth, n, j: Integer; q, r, len, fend: SizeInt; ct: Integer;
    size, ss: Int64;   { 32-bit sizes: Int64, so that q + size never wraps on i386 }
    c: TFliChunk;
begin
  Result := nil; n := 0;
  len := Length(d);
  if len < 128 then Exit;
  magic := Le16(d, 4);
  if (magic <> $AF11) and (magic <> $AF12) then Exit;
  w := Le16(d, 8); h := Le16(d, 10); depth := Le16(d, 12);
  if (w < 1) or (h < 1) or ((depth <> 8) and (depth <> 0)) then Exit;
  if SizeInt(w) * h > SizeInt(1) shl 26 then Exit;
  q := 128;
  while q + 6 <= len do begin
    size := Le32(d, q);
    if (size < 6) or (q + size > len) then Break;
    if Le16(d, q + 4) = $F1FA then begin
      if size < 16 then Break;
      fend := q + size;
      r := q + 16;
      for j := 1 to Le16(d, q + 6) do begin
        if r + 6 > fend then Break;
        ss := Le32(d, r);
        if (ss < 6) or (r + ss > fend) then Break;
        ct := Le16(d, r + 4);
        if ct in [CT_DELTA_FLC, CT_DELTA_FLI, CT_BLACK, CT_BYTE_RUN, CT_COPY] then begin
          c.dataStart := r + 6; c.dataEnd := r + ss;
          c.ctype := ct; c.width := w; c.height := h; c.stream := 0;
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
  tmx.Init(Length(tt) + 2, 16 * 16, 1, 11);
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
    p := tmx.Mix((kind and 15) * 16 + (bits - 1 - b));
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

constructor TFliImage.Create(aw, ah: Integer);
begin
  inherited Create;
  w := aw; h := ah;
  img := nil;
  SetLength(img, SizeInt(w) * h);
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

procedure CodeChunk(cd: TCoder; m: TFliModel; im: TFliImage; ctype: Integer;
                    var data: TBytes; len: SizeInt);
var wk: TWalk; last: Integer;
begin
  wk.cd := cd; wk.m := m; wk.im := im;
  wk.old := Copy(im.img, 0, Length(im.img));
  if not cd.encoding then begin data := nil; SetLength(data, len); end;
  wk.buf := data; wk.pos := 0; wk.len := len;
  case ctype of
    CT_BYTE_RUN: WalkByteRun(wk);
    CT_DELTA_FLI: WalkDeltaFli(wk);
    CT_DELTA_FLC: WalkDeltaFlc(wk);
    CT_COPY: WalkCopy(wk);
    CT_BLACK: if Length(im.img) > 0 then FillChar(im.img[0], Length(im.img), 0);
  end;
  { whatever the structure did not use }
  last := 0;
  while wk.pos < wk.len do last := wk.TB(K_TRAIL, last, 0);
  data := wk.buf;
end;

end.
