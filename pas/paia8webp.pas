{ FROZEN: the decoder of codec stream version 8, as PAIA 0.1.0 and 0.2.0 wrote it
  (a copy of paiawebp.pas at v0.2.0 = 60b2031, units renamed paia8*). Version 8
  is read forever, bit for bit (doc/STABILITY.md): never change this file;
  the live codec (paiawebp.pas) writes version 9 and up. }
{ WebP: finding the VP8L bitstreams of a file (lossless frames, and the
  lossless alpha of ALPH chunks), and coding them.

  A VP8L bitstream is a sequence of fields: header bits, transforms with
  their sub-images, the colour cache and meta prefix codes, prefix
  (Huffman) codes given by their code lengths, and the pixels as prefix-
  coded symbols: literals (green, red, blue, alpha), LZ77 copies (a length
  and a 2-D distance, each a prefix symbol and extra bits) and colour cache
  references. The encoder's choices are many (transforms, codes, matches),
  and none is guessed here: the stream is walked field by field, as a
  decoder reads it, and each field's VALUE is coded (a symbol, not its
  Huffman bits; the Huffman codes themselves as their code lengths are
  written). Extracting walks the same fields, decoding the values and
  writing each one as the stream had it: a symbol with its own code, under
  the same code lengths. So the bits come back exactly, by construction.

  The pixels are modelled from what is already decoded of the same image
  (the left, up and diagonal pixels, channel by channel, the green of the
  same pixel for the other channels) and from the previous frame's image
  of the same size. Pixel values are only context: an error there would
  cost compression, never exactness.

  One walk does three things: checks a stream (nothing coded), encodes it
  (reading bits, coding values) and decodes it (decoding values, writing
  bits), so the three cannot disagree. A stream that the check refuses
  stays as bytes. }
unit paia8webp;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paia8webp: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paia8webp: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paia8arith, paia8dib;

const
  WK_VP8L = 0;      { a VP8L chunk: the bitstream with its 5-byte header }
  WK_ALPH = 1;      { an ALPH chunk's lossless data: no header, the frame's size }

type
  TWebpStream = record
    dataStart, dataEnd: SizeInt;
    sub: Integer;                    { WK_* }
    width, height: Integer;          { for WK_ALPH }
    { a frame of an animation: where it goes on the canvas }
    inFrame, blend, dispose: Boolean;
    cw, ch, fx, fy, fw, fh: Integer;
  end;
  TWebpStreams = array of TWebpStream;

  { tokens of up to 24 bits }
  TBitsModel = class
  private
    tt: array[0..2] of TCounters;
    mx: TMixer;
  public
    constructor Create(tableBits: Integer);
    function Code(cd: TCoder; v, nbits, kind, c1, c2: Integer): Integer;
  end;

  { what one file's streams share }
  TWebpState = class
    bm: TBitsModel;
    pm: TDibModel;
    prev: array[0..1] of record w, h: Integer; px: array of LongWord; end;
    { the animation's canvas, in colours (ARGB), as the frames compose it }
    canvas: array of LongWord;
    cw, ch: Integer;
    disposeRect: Boolean; dx, dy, dw, dh: Integer;
    constructor Create(tableBits: Integer);
    destructor Destroy; override;
  end;

{ The VP8L streams of the WebP at the start of d that a decoder accepts. }
function FindWebpStreams(const d: TBytes): TWebpStreams;

procedure CodeWebpStream(cd: TCoder; st: TWebpState; const s: TWebpStream;
                         var data: TBytes; len: SizeInt);

implementation

const
  NONE = 256;
  MAX_PIXELS = SizeInt(1) shl 26;

  { token kinds }
  K_HDR = 1; K_TRANS = 2; K_CACHE = 3; K_META = 4; K_SIMPLE = 5; K_CLCL = 6;
  K_MAXSYM = 7; K_CLSYM = 8; K_REPEAT = 9; K_TYPE = 10; K_LENP = 11; K_LENX = 12;
  K_DISTP = 13; K_DISTX = 14; K_CACHEIDX = 15; K_TRAIL = 16; K_PAD = 17;

  { green, red, blue, alpha: their byte in an ARGB word }
  CHAN_BYTE: array[0..3] of Integer = (1, 2, 0, 3);

  CODE_LENGTH_ORDER: array[0..18] of Integer =
    (17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

  CODE_TO_PLANE: array[0..119] of Byte = (
    $18, $07, $17, $19, $28, $06, $27, $29, $16, $1a,
    $26, $2a, $38, $05, $37, $39, $15, $1b, $36, $3a,
    $25, $2b, $48, $04, $47, $49, $14, $1c, $35, $3b,
    $46, $4a, $24, $2c, $58, $45, $4b, $34, $3c, $03,
    $57, $59, $13, $1d, $56, $5a, $23, $2d, $44, $4c,
    $55, $5b, $33, $3d, $68, $02, $67, $69, $12, $1e,
    $66, $6a, $22, $2e, $54, $5c, $43, $4d, $65, $6b,
    $32, $3e, $78, $01, $77, $79, $53, $5d, $11, $1f,
    $64, $6c, $42, $4e, $76, $7a, $21, $2f, $75, $7b,
    $31, $3f, $63, $6d, $52, $5e, $00, $74, $7c, $41,
    $4f, $10, $20, $62, $6e, $30, $73, $7d, $51, $5f,
    $40, $72, $7e, $61, $6f, $50, $71, $7f, $60, $70);

function Hash(a, b: QWord): QWord; inline;
begin
  Result := ((a + 1) * QWord($9E3779B1)) and $FFFFFFFF;
  Result := ((Result xor b) * QWord($85EBCA6B)) and $FFFFFFFF;
  Result := Result xor (Result shr 15);
end;

function Le24(const d: TBytes; p: SizeInt): Integer; inline;
begin
  Result := d[p] or (d[p + 1] shl 8) or (d[p + 2] shl 16);
end;

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

function DivRound(a, b: Integer): Integer; inline;
begin
  Result := (a + b - 1) div b;
end;

{ ---------------- the token model ---------------- }

constructor TBitsModel.Create(tableBits: Integer);
var i: Integer;
begin
  inherited Create;
  for i := 0 to High(tt) do tt[i].Init(tableBits, 255);
  mx.Init(Length(tt) + 1, 32 * 12, 1, 11);
end;

function TBitsModel.Code(cd: TCoder; v, nbits, kind, c1, c2: Integer): Integer;
var b, bit, node, j, p, hi: Integer; idx: array[0..2] of SizeInt; h: array[0..2] of QWord;
begin
  if nbits > 12 then begin
    { the high bits, then the low twelve }
    hi := Code(cd, v shr 12, nbits - 12, kind + 32, c1, c2);
    Result := (hi shl 12) or Code(cd, v and $FFF, 12, kind, c1, hi);
    Exit;
  end;
  h[0] := Hash(kind * 32 + nbits, 0);
  h[1] := Hash(Hash(kind * 32 + nbits, c1), 1);
  h[2] := Hash(Hash(kind * 32 + nbits, c1), c2 + 2 * 65536);
  node := 1;
  for b := nbits - 1 downto 0 do begin
    for j := 0 to 2 do begin
      idx[j] := Hash(h[j], node) and tt[j].mask;
      mx.Add(Stretch(tt[j].P12(idx[j])));
    end;
    mx.Add(256);
    p := mx.Mix((kind and 31) * 12 + (nbits - 1 - b) mod 12);
    bit := cd.Code((v shr b) and 1, p);
    for j := 0 to 2 do tt[j].Update(idx[j], bit);
    mx.Update(bit);
    node := node * 2 + bit;
  end;
  Result := node - (1 shl nbits);
end;

constructor TWebpState.Create(tableBits: Integer);
begin
  inherited Create;
  bm := TBitsModel.Create(tableBits - 2);
  pm := TDibModel.Create(tableBits);
end;

destructor TWebpState.Destroy;
begin
  bm.Free; pm.Free;
  inherited;
end;

{ ---------------- prefix codes ---------------- }

type
  THuff = record
    n: Integer;                         { alphabet size }
    len: array of Byte;                 { per symbol }
    code: array of LongWord;            { per symbol, canonical }
    single: Integer;                    { the only symbol of a zero-bit code, or -1 }
    { canonical decoding }
    count: array[0..15] of Integer;
    first: array[0..15] of LongInt;
    offs: array[0..15] of Integer;
    sorted: array of Integer;
    maxLen: Integer;
    function Build: Boolean;            { from len; False if not a full code }
    function Bits(s: Integer): Integer; inline;
  end;

function THuff.Build: Boolean;
var i, l, nz, c: Integer; left: Int64; next: array[0..15] of LongInt;
begin
  Result := False;
  FillChar(count, SizeOf(count), 0);
  nz := 0; single := -1; maxLen := 0;
  for i := 0 to n - 1 do
    if len[i] > 0 then begin
      if len[i] > 15 then Exit;
      Inc(count[len[i]]); Inc(nz); single := i;
      if len[i] > maxLen then maxLen := len[i];
    end;
  if nz = 0 then Exit;
  SetLength(code, n);
  if nz = 1 then begin Result := True; Exit; end;   { zero bits: `single` }
  single := -1;
  { a full code: the lengths' Kraft sum is exactly one }
  left := 1;
  for l := 1 to 15 do begin
    left := left * 2 - count[l];
    if left < 0 then Exit;
  end;
  if left <> 0 then Exit;
  c := 0;
  for l := 1 to 15 do begin
    c := (c + count[l - 1]) shl 1;
    next[l] := c;
    first[l] := c;
  end;
  SetLength(sorted, nz);
  offs[1] := 0;
  for l := 2 to 15 do offs[l] := offs[l - 1] + count[l - 1];
  for l := 1 to 15 do next[l] := first[l];
  for i := 0 to n - 1 do
    if len[i] > 0 then begin
      code[i] := next[len[i]];
      sorted[offs[len[i]] + (next[len[i]] - first[len[i]])] := i;
      Inc(next[len[i]]);
    end;
  Result := True;
end;

function THuff.Bits(s: Integer): Integer; inline;
begin
  if single >= 0 then Result := 0 else Result := len[s];
end;

{ ---------------- bits ---------------- }

type
  TBitIO = record
    d: TBytes;
    len: SizeInt;
    bitPos: Int64;            { reading: the next bit; writing: bits written }
    bad: Boolean;
    function Read(n: Integer): Integer;
    procedure Write(v: LongWord; n: Integer);
  end;

function TBitIO.Read(n: Integer): Integer;
var i: Integer; p: Int64;
begin
  Result := 0;
  for i := 0 to n - 1 do begin
    p := bitPos + i;
    if (p shr 3) >= len then begin bad := True; Exit(0); end;
    if (d[p shr 3] shr (p and 7)) and 1 <> 0 then Result := Result or (1 shl i);
  end;
  bitPos := bitPos + n;
end;

procedure TBitIO.Write(v: LongWord; n: Integer);
var i: Integer; p: Int64;
begin
  for i := 0 to n - 1 do begin
    p := bitPos + i;
    if (p shr 3) >= len then begin bad := True; Exit; end;
    if (v shr i) and 1 <> 0 then d[p shr 3] := d[p shr 3] or (1 shl (p and 7));
  end;
  bitPos := bitPos + n;
end;

{ ---------------- the walk ---------------- }

const
  MODE_CHECK = 0; MODE_ENC = 1; MODE_DEC = 2;

type
  TImage = array of LongWord;

  TWalk = record
    mode: Integer;
    cd: TCoder;
    st: TWebpState;
    io: TBitIO;
    fail: Boolean;
    prevPx: TImage; prevW, prevH: Integer;   { the previous frame's main image }
    predImg: TImage; predBits, predW: Integer;  { the predictor transform's modes }
    { the colour indexing transform: the palette, and its index lookup }
    palette: TImage; palBits: Integer;
    palKey: array of LongWord; palIdx: array of SmallInt;
    { the frame on the canvas }
    useCanvas: Boolean; cs: TWebpStream;
    function PalLookup(c: LongWord): Integer;
    procedure SetPalette(const sub: TImage; bits: Integer);
    function Field(n, kind, c1: Integer): Integer;
    function Sym(var h: THuff; kind, c1, c2: Integer): Integer;
    { a literal channel byte: through the pixel model }
    function Chan(var h: THuff; const c: array of Integer): Integer;
    procedure Emit(var h: THuff; s: Integer);
    function ReadSym(var h: THuff): Integer;
    function ReadCode(var h: THuff; alphabet, kind: Integer): Boolean;
    function DecodeImage(w, h: Integer; level0: Boolean; chanBase: Integer; out px: TImage): Boolean;
  end;

procedure TWalk.SetPalette(const sub: TImage; bits: Integer);
var i: Integer; h: LongWord; c: LongWord;
begin
  palBits := bits;
  palette := nil; SetLength(palette, Length(sub));
  for i := 0 to High(sub) do begin
    if i = 0 then palette[i] := sub[i]
    else
      { each entry is the difference from the one before, channel by channel }
      palette[i] := (((sub[i] and $FF00FF00) + (palette[i - 1] and $FF00FF00)) and $FF00FF00) or
                    (((sub[i] and $00FF00FF) + (palette[i - 1] and $00FF00FF)) and $00FF00FF);
  end;
  palKey := nil; palIdx := nil;
  SetLength(palKey, 1024); SetLength(palIdx, 1024);
  for i := 0 to 1023 do palIdx[i] := -1;
  for i := 0 to High(palette) do begin
    c := palette[i];
    h := ((QWord(c) * $9E3779B1) and $FFFFFFFF) shr 22;
    while (palIdx[h] >= 0) and (palKey[h] <> c) do h := (h + 1) and 1023;
    if palIdx[h] < 0 then begin palKey[h] := c; palIdx[h] := i; end;
  end;
end;

function TWalk.PalLookup(c: LongWord): Integer;
var h: LongWord;
begin
  if palIdx = nil then Exit(-1);
  h := ((QWord(c) * $9E3779B1) and $FFFFFFFF) shr 22;
  while palIdx[h] >= 0 do begin
    if palKey[h] = c then Exit(palIdx[h]);
    h := (h + 1) and 1023;
  end;
  Result := -1;
end;

function TWalk.Field(n, kind, c1: Integer): Integer;
begin
  if fail then Exit(0);
  case mode of
    MODE_CHECK: begin Result := io.Read(n); if io.bad then fail := True; end;
    MODE_ENC: begin
      Result := io.Read(n); if io.bad then begin fail := True; Exit; end;
      if n > 0 then st.bm.Code(cd, Result, n, kind, c1, 0);
    end;
  else begin
    if n > 0 then Result := st.bm.Code(cd, 0, n, kind, c1, 0) else Result := 0;
    io.Write(Result, n);
  end;
  end;
end;

function TWalk.ReadSym(var h: THuff): Integer;
var l, c, b: Integer;
begin
  if h.single >= 0 then Exit(h.single);
  c := 0;
  for l := 1 to h.maxLen do begin
    b := io.Read(1);
    if io.bad then begin fail := True; Exit(0); end;
    c := (c shl 1) or b;
    if (h.count[l] > 0) and (c - h.first[l] < h.count[l]) and (c >= h.first[l]) then
      Exit(h.sorted[h.offs[l] + c - h.first[l]]);
  end;
  fail := True; Result := 0;
end;

procedure TWalk.Emit(var h: THuff; s: Integer);
var l, i: Integer;
begin
  if h.single >= 0 then Exit;
  if (s < 0) or (s >= h.n) or (h.len[s] = 0) then begin fail := True; Exit; end;
  l := h.len[s];
  { the code's bits from its top, each the next bit of the stream }
  for i := l - 1 downto 0 do io.Write((h.code[s] shr i) and 1, 1);
end;

function NBits(n: Integer): Integer;
begin
  Result := 1;
  while (1 shl Result) < n do Inc(Result);
end;

function TWalk.Sym(var h: THuff; kind, c1, c2: Integer): Integer;
begin
  if fail then Exit(0);
  case mode of
    MODE_CHECK: Result := ReadSym(h);
    MODE_ENC: begin
      Result := ReadSym(h);
      if (h.single < 0) and not fail then st.bm.Code(cd, Result, NBits(h.n), kind, c1, c2);
    end;
  else begin
    if h.single >= 0 then Result := h.single
    else begin
      Result := st.bm.Code(cd, 0, NBits(h.n), kind, c1, c2);
      Emit(h, Result);
    end;
  end;
  end;
end;

function TWalk.Chan(var h: THuff; const c: array of Integer): Integer;
begin
  if fail then Exit(0);
  case mode of
    MODE_CHECK: Result := ReadSym(h);
    MODE_ENC: begin
      Result := ReadSym(h);
      if (h.single < 0) and not fail then st.pm.Code(cd, Result, c);
    end;
  else begin
    if h.single >= 0 then Result := h.single
    else begin
      Result := st.pm.Code(cd, 0, c);
      Emit(h, Result);
    end;
  end;
  end;
end;

function TWalk.ReadCode(var h: THuff; alphabet, kind: Integer): Boolean;
var simple, nsym, first8, s0, s1, ncl, i, maxSym, si, cl, prevLen, rep, lnb: Integer;
    clh: THuff;
begin
  Result := False;
  h.n := alphabet;
  h.len := nil; SetLength(h.len, alphabet);
  simple := Field(1, K_SIMPLE, kind);
  if simple = 1 then begin
    nsym := Field(1, K_SIMPLE, 2 + kind * 4);
    first8 := Field(1, K_SIMPLE, 3 + kind * 4);
    s0 := Field(1 + 7 * first8, K_SIMPLE, 4 + kind * 4);
    if fail or (s0 >= alphabet) then begin fail := True; Exit; end;
    h.len[s0] := 1;
    if nsym = 1 then begin
      s1 := Field(8, K_SIMPLE, 5 + kind * 4);
      if fail or (s1 >= alphabet) then begin fail := True; Exit; end;
      h.len[s1] := 1;
    end;
  end else begin
    ncl := Field(4, K_CLCL, 100) + 4;
    clh.n := 19;
    clh.len := nil; SetLength(clh.len, 19);
    for i := 0 to ncl - 1 do clh.len[CODE_LENGTH_ORDER[i]] := Field(3, K_CLCL, i);
    if fail or not clh.Build then begin fail := True; Exit; end;
    if Field(1, K_MAXSYM, 0) = 1 then begin
      lnb := 2 + 2 * Field(3, K_MAXSYM, 1);
      maxSym := 2 + Field(lnb, K_MAXSYM, 2);
      if maxSym > alphabet then begin fail := True; Exit; end;
    end else maxSym := alphabet;
    si := 0; prevLen := 8;
    while (si < alphabet) and not fail do begin
      if maxSym = 0 then Break;
      Dec(maxSym);
      cl := Sym(clh, K_CLSYM, prevLen, kind);
      if fail then Exit;
      if cl < 16 then begin
        h.len[si] := cl; Inc(si);
        if cl <> 0 then prevLen := cl;
      end else begin
        case cl of
          16: rep := 3 + Field(2, K_REPEAT, 0);
          17: rep := 3 + Field(3, K_REPEAT, 1);
        else rep := 11 + Field(7, K_REPEAT, 2);
        end;
        if si + rep > alphabet then begin fail := True; Exit; end;
        for i := 1 to rep do begin
          if cl = 16 then h.len[si] := prevLen else h.len[si] := 0;
          Inc(si);
        end;
      end;
    end;
  end;
  if fail or not h.Build then begin fail := True; Exit; end;
  Result := True;
end;

function PrefixExtraBits(prefix: Integer): Integer; inline;
begin
  if prefix < 4 then Result := 0 else Result := (prefix - 2) shr 1;
end;

function PrefixValue(prefix, extra: Integer): Integer; inline;
var eb: Integer;
begin
  if prefix < 4 then Exit(prefix + 1);
  eb := (prefix - 2) shr 1;
  Result := ((2 + (prefix and 1)) shl eb) + extra + 1;
end;

function PlaneDistance(xsize, code: Integer): Integer;
var dc, yo, xo: Integer;
begin
  if code > 120 then Exit(code - 120);
  dc := CODE_TO_PLANE[code - 1];
  yo := dc shr 4;
  xo := 8 - (dc and $F);
  Result := yo * xsize + xo;
  if Result < 1 then Result := 1;
end;

function Clip(x: Integer): Integer; inline;
begin
  if x < 0 then Result := 0 else if x > 255 then Result := 255 else Result := x;
end;

function TWalk.DecodeImage(w, h: Integer; level0: Boolean; chanBase: Integer; out px: TImage): Boolean;
var cacheBits, metaBits, mw, ngroups, g, i, k, x, y, s, t, lastType, lp, dp, len, dist,
    extra, alphabet: Integer;
    total, pos, j: SizeInt; meta: TImage; codes: array of array[0..4] of THuff;
    cache: array of LongWord; argb: LongWord; c: array[0..8] of Integer;
    usePrev: Boolean; lastLp, lastDp, pmode, canvasPred, transpPacked, ti, tctx: Integer;
  function CanvasIndex(px0, py0: Integer): Integer;
  var per, bpp, k2, ux, cx, cy, idx: Integer;
  begin
    per := 1 shl palBits; bpp := 8 shr palBits;
    Result := 0;
    cy := cs.fy + py0;
    for k2 := 0 to per - 1 do begin
      ux := px0 * per + k2;
      if ux >= cs.fw then Break;
      cx := cs.fx + ux;
      if (cx >= st.cw) or (cy >= st.ch) then Exit(-1);
      idx := PalLookup(st.canvas[SizeInt(cy) * st.cw + cx]);
      if idx < 0 then Exit(-1);
      Result := Result or (idx shl (k2 * bpp));
    end;
    Result := Result and 255;
  end;
  function Ch(p: SizeInt; chn: Integer): Integer; inline;
  begin
    Result := (px[p] shr (8 * chn)) and 255;
  end;
begin
  Result := False;
  px := nil;
  if (w < 1) or (h < 1) or (SizeInt(w) * h > MAX_PIXELS) then begin fail := True; Exit; end;
  total := SizeInt(w) * h;
  cacheBits := 0;
  if Field(1, K_CACHE, Ord(level0)) = 1 then begin
    cacheBits := Field(4, K_CACHE, 2);
    if (cacheBits < 1) or (cacheBits > 11) then begin fail := True; Exit; end;
  end;
  metaBits := 0; mw := 0; ngroups := 1; meta := nil;
  if level0 and (Field(1, K_META, 0) = 1) then begin
    metaBits := Field(3, K_META, 1) + 2;
    mw := DivRound(w, 1 shl metaBits);
    if not DecodeImage(mw, DivRound(h, 1 shl metaBits), False, 4, meta) then begin fail := True; Exit; end;
    for j := 0 to High(meta) do begin
      meta[j] := (meta[j] shr 8) and $FFFF;
      if Integer(meta[j]) + 1 > ngroups then ngroups := meta[j] + 1;
    end;
  end;
  if fail then Exit;
  SetLength(codes, ngroups);
  alphabet := 256 + 24;
  if cacheBits > 0 then alphabet := alphabet + (1 shl cacheBits);
  for g := 0 to ngroups - 1 do begin
    if not ReadCode(codes[g][0], alphabet, 0) then Exit;
    if not ReadCode(codes[g][1], 256, 1) then Exit;
    if not ReadCode(codes[g][2], 256, 2) then Exit;
    if not ReadCode(codes[g][3], 256, 3) then Exit;
    if not ReadCode(codes[g][4], 40, 4) then Exit;
  end;
  SetLength(px, total);
  cache := nil;
  if cacheBits > 0 then SetLength(cache, 1 shl cacheBits);
  usePrev := level0 and (prevPx <> nil) and (prevW = w) and (prevH = h);
  pmode := 0;
  { the palette's first fully transparent entry, packed as a pixel would be }
  transpPacked := NONE;
  if level0 and (palette <> nil) then
    for ti := 0 to High(palette) do
      if (palette[ti] shr 24) = 0 then begin
        transpPacked := 0;
        for k := 0 to (1 shl palBits) - 1 do
          transpPacked := transpPacked or (ti shl (k * (8 shr palBits)));
        transpPacked := transpPacked and 255;
        Break;
      end;
  pos := 0; x := 0; y := 0; lastType := 0; lastLp := 0; lastDp := 0; argb := 0;
  while (pos < total) and not fail do begin
    if metaBits > 0 then g := meta[SizeInt(y shr metaBits) * mw + (x shr metaBits)] else g := 0;
    { what the canvas shows under this pixel, as this frame's palette
      indices packed as the pixel packs them }
    canvasPred := -1;
    if level0 and useCanvas and (palette <> nil) then canvasPred := CanvasIndex(x, y);
    if canvasPred < 0 then tctx := 0
    else if canvasPred = transpPacked then tctx := 1
    else if (x > 0) and (canvasPred = Integer((px[pos - 1] shr 8) and 255)) then tctx := 2
    else tctx := 3;
    { the green symbol: a literal, a copy's length prefix, or a cache index;
      coded as its type first, then the value }
    if mode <> MODE_DEC then begin
      s := ReadSym(codes[g][0]);
      if fail then Break;
      if s < 256 then t := 0 else if s < 280 then t := 1 else t := 2;
      { the type: a symbol of its own, unless the code allows only one }
    end else begin s := 0; t := 0; end;
    if codes[g][0].single < 0 then begin
      if mode = MODE_ENC then st.bm.Code(cd, t, 2, K_TYPE + 64 * Ord(level0), lastType, tctx)
      else if mode = MODE_DEC then t := st.bm.Code(cd, 0, 2, K_TYPE + 64 * Ord(level0), lastType, tctx);
    end else if mode = MODE_DEC then begin
      s := codes[g][0].single;
      if s < 256 then t := 0 else if s < 280 then t := 1 else t := 2;
    end;
    lastType := t;
    { the neighbourhood }
    for k := 1 to 8 do c[k] := NONE;
    case t of
      0: begin
        { the predictor's mode where this pixel is (main image only) }
        if level0 and (predImg <> nil) then begin
          j := SizeInt(y shr predBits) * predW + (x shr predBits);
          if j < Length(predImg) then pmode := 1 + ((predImg[j] shr 8) and 15) else pmode := 0;
        end;
        { green, red, blue, alpha; each with its neighbours in this image }
        for k := 0 to 3 do begin
          i := CHAN_BYTE[k];                      { the channel's byte in ARGB }
          c[0] := chanBase + k + 8 * pmode;
          if x > 0 then c[1] := Ch(pos - 1, i) else c[1] := NONE;
          if y > 0 then begin
            c[2] := Ch(pos - w, i);
            if x > 0 then c[3] := Ch(pos - w - 1, i) else c[3] := NONE;
            if x + 1 < w then c[4] := Ch(pos - w + 1, i) else c[4] := NONE;
          end else begin c[2] := NONE; c[3] := NONE; c[4] := NONE; end;
          if usePrev then c[5] := (prevPx[pos] shr (8 * i)) and 255
          else if (k = 0) and (canvasPred >= 0) then c[5] := canvasPred
          else c[5] := NONE;
          if (c[1] <> NONE) and (c[2] <> NONE) and (c[3] <> NONE) then c[6] := Clip(c[1] + c[2] - c[3])
          else if c[1] <> NONE then c[6] := c[1] else c[6] := c[2];
          if k > 0 then begin
            c[7] := (argb shr 8) and 255;          { this pixel's green }
            if x > 0 then c[8] := Clip(Ch(pos - 1, i) - Ch(pos - 1, 1) + 128) else c[8] := NONE;
          end else if canvasPred >= 0 then begin
            { the canvas's index, with the transparent one: a frame drawn
              over the one before leaves unchanged pixels transparent }
            c[7] := transpPacked; c[8] := canvasPred;
          end else begin c[7] := NONE; c[8] := NONE; end;
          if k = 0 then begin
            if mode = MODE_DEC then begin
              if codes[g][0].single >= 0 then s := codes[g][0].single
              else begin s := st.pm.Code(cd, 0, c); Emit(codes[g][0], s); end;
            end else if (mode = MODE_ENC) and (codes[g][0].single < 0) then
              st.pm.Code(cd, s, c);
            argb := LongWord(s) shl 8;
          end else
            argb := argb or (LongWord(Chan(codes[g][k], c)) shl (8 * i));
          if fail then Break;
        end;
        if fail then Break;
        px[pos] := argb;
        if cacheBits > 0 then
          cache[((QWord($1e35a7bd) * argb) and $FFFFFFFF) shr (32 - cacheBits)] := argb;
        Inc(pos); Inc(x); if x = w then begin x := 0; Inc(y); end;
      end;
      1: begin
        { a copy: the length's prefix and extra bits, the distance's }
        if (mode = MODE_DEC) and (codes[g][0].single >= 0) then
          lp := codes[g][0].single - 256
        else if mode = MODE_DEC then begin
          lp := st.bm.Code(cd, 0, 5, K_LENP, lastLp, Ord(level0));
          if lp > 23 then begin fail := True; Break; end;
          s := 256 + lp;
          Emit(codes[g][0], s);
        end else begin
          lp := s - 256;
          if (mode = MODE_ENC) and (codes[g][0].single < 0) then
            st.bm.Code(cd, lp, 5, K_LENP, lastLp, Ord(level0));
        end;
        lastLp := lp;
        extra := Field(PrefixExtraBits(lp), K_LENX, lp);
        len := PrefixValue(lp, extra);
        dp := Sym(codes[g][4], K_DISTP, lastDp, Ord(level0));
        lastDp := dp;
        extra := Field(PrefixExtraBits(dp), K_DISTX, dp);
        if fail then Break;
        dist := PlaneDistance(w, PrefixValue(dp, extra));
        if (dist > pos) or (pos + len > total) then begin fail := True; Break; end;
        for j := 0 to len - 1 do begin
          argb := px[pos - dist];
          px[pos] := argb;
          if cacheBits > 0 then
            cache[((QWord($1e35a7bd) * argb) and $FFFFFFFF) shr (32 - cacheBits)] := argb;
          Inc(pos); Inc(x); if x = w then begin x := 0; Inc(y); end;
        end;
      end;
    else begin
      { a cache reference }
      if cacheBits = 0 then begin fail := True; Break; end;
      if (mode = MODE_DEC) and (codes[g][0].single >= 0) then
        k := codes[g][0].single - 280
      else if mode = MODE_DEC then begin
        k := st.bm.Code(cd, 0, cacheBits, K_CACHEIDX, Ord(level0), 0);
        s := 280 + k;
        Emit(codes[g][0], s);
      end else begin
        k := s - 280;
        if (mode = MODE_ENC) and (codes[g][0].single < 0) then
          st.bm.Code(cd, k, cacheBits, K_CACHEIDX, Ord(level0), 0);
      end;
      if k >= (1 shl cacheBits) then begin fail := True; Break; end;
      argb := cache[k];
      px[pos] := argb;
      cache[((QWord($1e35a7bd) * argb) and $FFFFFFFF) shr (32 - cacheBits)] := argb;
      Inc(pos); Inc(x); if x = w then begin x := 0; Inc(y); end;
    end;
    end;
  end;
  Result := not fail;
end;

{ The whole stream: header (VP8L), transforms, the main image, what follows. }
function WalkStream(var wk: TWalk; const s: TWebpStream; out mainW, mainH: Integer;
                    out main: TImage): Boolean;
var w, h, xs, t, seen, bits, size: Integer; sub: TImage;
begin
  Result := False; main := nil; mainW := 0; mainH := 0;
  if s.sub = WK_VP8L then begin
    if wk.Field(8, K_HDR, 0) <> $2F then begin wk.fail := True; Exit; end;
    w := wk.Field(14, K_HDR, 1) + 1;
    h := wk.Field(14, K_HDR, 2) + 1;
    wk.Field(1, K_HDR, 3);
    if wk.Field(3, K_HDR, 4) <> 0 then begin wk.fail := True; Exit; end;
  end else begin w := s.width; h := s.height; end;
  if wk.fail then Exit;
  xs := w; seen := 0;
  while wk.Field(1, K_TRANS, seen) = 1 do begin
    t := wk.Field(2, K_TRANS, 16);
    if wk.fail or ((seen shr t) and 1 <> 0) then begin wk.fail := True; Exit; end;
    seen := seen or (1 shl t);
    case t of
      0, 1: begin
        bits := wk.Field(3, K_TRANS, 17 + t) + 2;
        if not wk.DecodeImage(DivRound(xs, 1 shl bits), DivRound(h, 1 shl bits), False, 4, sub) then Exit;
        if t = 0 then begin
          wk.predImg := sub; wk.predBits := bits; wk.predW := DivRound(xs, 1 shl bits);
        end;
      end;
      3: begin
        size := wk.Field(8, K_TRANS, 19) + 1;
        if not wk.DecodeImage(size, 1, False, 4, sub) then Exit;
        if size > 16 then bits := 0 else if size > 4 then bits := 1
        else if size > 2 then bits := 2 else bits := 3;
        xs := DivRound(xs, 1 shl bits);
        wk.SetPalette(sub, bits);
      end;
    end;
  end;
  if wk.fail then Exit;
  if not wk.DecodeImage(xs, h, True, 0, main) then Exit;
  mainW := xs; mainH := h;
  Result := True;
end;

{ The frame's colours onto the canvas (only when they are known: a
  palette image), as a viewer composes them: a transparent pixel of a
  blended frame leaves the canvas as it was. Then, if the frame is
  disposed of, its rectangle is cleared before the next one. }
procedure Compose(var wk: TWalk; const main: TImage; mw: Integer);
var x, y, per, bpp, idx, cx, cy: Integer; g: LongWord; col: LongWord; st: TWebpState;
begin
  st := wk.st;
  if (wk.palette <> nil) and (mw > 0) then begin
    per := 1 shl wk.palBits; bpp := 8 shr wk.palBits;
    for y := 0 to wk.cs.fh - 1 do begin
      cy := wk.cs.fy + y;
      if cy >= st.ch then Break;
      for x := 0 to wk.cs.fw - 1 do begin
        cx := wk.cs.fx + x;
        if cx >= st.cw then Break;
        if SizeInt(y) * mw + (x div per) >= Length(main) then Break;
        g := (main[SizeInt(y) * mw + (x div per)] shr 8) and 255;
        idx := (g shr ((x mod per) * bpp)) and ((1 shl bpp) - 1);
        if idx < Length(wk.palette) then col := wk.palette[idx] else col := 0;
        if wk.cs.blend and ((col shr 24) = 0) then Continue;
        st.canvas[SizeInt(cy) * st.cw + cx] := col;
      end;
    end;
  end;
  st.disposeRect := wk.cs.dispose;
  st.dx := wk.cs.fx; st.dy := wk.cs.fy; st.dw := wk.cs.fw; st.dh := wk.cs.fh;
end;

procedure RunWalk(var wk: TWalk; const s: TWebpStream; len: SizeInt);
var mw, mh, padN, last: Integer; main: TImage; p: SizeInt;
begin
  if not WalkStream(wk, s, mw, mh, main) then Exit;
  { the padding bits of the last byte, then any bytes left }
  padN := (8 - (wk.io.bitPos and 7)) and 7;
  wk.Field(padN, K_PAD, 0);
  last := 0;
  p := wk.io.bitPos shr 3;
  while (p < len) and not wk.fail do begin
    last := wk.Field(8, K_TRAIL, last);
    Inc(p);
  end;
  if wk.mode <> MODE_CHECK then begin
    wk.st.prev[s.sub].w := mw; wk.st.prev[s.sub].h := mh;
    wk.st.prev[s.sub].px := main;
    if wk.useCanvas and not wk.fail then Compose(wk, main, mw);
  end;
end;

{ ---------------- finding the streams ---------------- }

function CheckStream(const d: TBytes; const s: TWebpStream): Boolean;
var wk: TWalk;
begin
  wk := Default(TWalk);
  wk.mode := MODE_CHECK;
  wk.io.d := Copy(d, s.dataStart, s.dataEnd - s.dataStart);
  wk.io.len := s.dataEnd - s.dataStart;
  RunWalk(wk, s, wk.io.len);
  Result := not wk.fail;
end;

type
  TFrameInfo = record
    inFrame, blend, dispose: Boolean;
    cw, ch, fx, fy, fw, fh: Integer;
  end;

procedure Add(const d: TBytes; var r: TWebpStreams; var n: Integer; a, b: SizeInt;
              sub, w, h: Integer; const fi: TFrameInfo);
var s: TWebpStream;
begin
  if b - a < 1 then Exit;
  s := Default(TWebpStream);
  s.dataStart := a; s.dataEnd := b; s.sub := sub; s.width := w; s.height := h;
  s.inFrame := fi.inFrame; s.blend := fi.blend; s.dispose := fi.dispose;
  s.cw := fi.cw; s.ch := fi.ch; s.fx := fi.fx; s.fy := fi.fy; s.fw := fi.fw; s.fh := fi.fh;
  if not CheckStream(d, s) then Exit;
  if n >= Length(r) then SetLength(r, n * 2 + 8);
  r[n] := s; Inc(n);
end;

procedure Walk(const d: TBytes; q, stop: SizeInt; fw, fh: Integer; var r: TWebpStreams;
               var n: Integer; depth: Integer; var fi: TFrameInfo);
var sz: Int64; sub: TFrameInfo;   { 32-bit size: Int64, no wrap on i386 }
begin
  while q + 8 <= stop do begin
    sz := Le32(d, q + 4);
    if q + 8 + sz > stop then Exit;
    if IsId(d, q, 'VP8X') and (sz >= 10) then begin
      fw := Le24(d, q + 12) + 1; fh := Le24(d, q + 15) + 1;
      fi.cw := fw; fi.ch := fh;
    end else if IsId(d, q, 'ANMF') and (sz >= 16) and (depth = 0) then begin
      sub := fi;
      sub.inFrame := True;
      sub.fx := 2 * Le24(d, q + 8); sub.fy := 2 * Le24(d, q + 11);
      sub.fw := Le24(d, q + 14) + 1; sub.fh := Le24(d, q + 17) + 1;
      sub.dispose := (d[q + 8 + 15] and 1) <> 0;
      sub.blend := (d[q + 8 + 15] and 2) = 0;
      Walk(d, q + 8 + 16, q + 8 + sz, sub.fw, sub.fh, r, n, 1, sub);
    end else if IsId(d, q, 'VP8L') then
      Add(d, r, n, q + 8, q + 8 + sz, WK_VP8L, 0, 0, fi)
    else if IsId(d, q, 'ALPH') and (sz >= 2) and ((d[q + 8] and 3) = 1) and (fw > 0) then
      Add(d, r, n, q + 9, q + 8 + sz, WK_ALPH, fw, fh, fi);
    q := q + 8 + sz + (sz and 1);
  end;
end;

function FindWebpStreams(const d: TBytes): TWebpStreams;
var n: Integer; stop: Int64; fi: TFrameInfo;
begin
  Result := nil; n := 0;
  if (Length(d) < 12) or not IsId(d, 0, 'RIFF') or not IsId(d, 8, 'WEBP') then Exit;
  stop := 8 + Le32(d, 4);
  if stop > Length(d) then stop := Length(d);
  fi := Default(TFrameInfo);
  Walk(d, 12, stop, 0, 0, Result, n, 0, fi);
  SetLength(Result, n);
end;

{ ---------------- coding ---------------- }

procedure CodeWebpStream(cd: TCoder; st: TWebpState; const s: TWebpStream;
                         var data: TBytes; len: SizeInt);
var wk: TWalk; x, y: Integer;
begin
  wk := Default(TWalk);
  wk.cd := cd; wk.st := st;
  wk.prevPx := st.prev[s.sub].px; wk.prevW := st.prev[s.sub].w; wk.prevH := st.prev[s.sub].h;
  wk.io.len := len;
  { an animation's VP8L frame: its canvas, as the frames before left it }
  if (s.sub = WK_VP8L) and s.inFrame and (s.cw > 0) and (s.ch > 0) and
     (SizeInt(s.cw) * s.ch <= MAX_PIXELS) then begin
    if (st.cw <> s.cw) or (st.ch <> s.ch) or (st.canvas = nil) then begin
      st.cw := s.cw; st.ch := s.ch;
      st.canvas := nil; SetLength(st.canvas, SizeInt(s.cw) * s.ch);
      st.disposeRect := False;
    end;
    if st.disposeRect then begin
      for y := st.dy to st.dy + st.dh - 1 do
        for x := st.dx to st.dx + st.dw - 1 do
          if (x < st.cw) and (y < st.ch) then st.canvas[SizeInt(y) * st.cw + x] := 0;
      st.disposeRect := False;
    end;
    wk.useCanvas := True;
    wk.cs := s;
  end;
  if cd.encoding then begin
    wk.mode := MODE_ENC;
    wk.io.d := data;
  end else begin
    wk.mode := MODE_DEC;
    wk.io.d := nil; SetLength(wk.io.d, len);
  end;
  RunWalk(wk, s, len);
  if wk.fail then raise Exception.Create('paia8webp: a stream that does not walk');
  data := wk.io.d;
end;

end.
