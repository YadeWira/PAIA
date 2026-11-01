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
unit paiawebp;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiawebp: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiawebp: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith, paiadib;

const
  WK_VP8L = 0;      { a VP8L chunk: the bitstream with its 5-byte header }
  WK_ALPH = 1;      { an ALPH chunk's lossless data: no header, the frame's size }

type
  TWebpStream = record
    dataStart, dataEnd: SizeInt;
    sub: Integer;                    { WK_* }
    width, height: Integer;          { for WK_ALPH }
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
  mx.Init(Length(tt) + 1, 32 * 12, 5);
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
    function Field(n, kind, c1: Integer): Integer;
    function Sym(var h: THuff; kind, c1, c2: Integer): Integer;
    { a literal channel byte: through the pixel model }
    function Chan(var h: THuff; const c: array of Integer): Integer;
    procedure Emit(var h: THuff; s: Integer);
    function ReadSym(var h: THuff): Integer;
    function ReadCode(var h: THuff; alphabet, kind: Integer): Boolean;
    function DecodeImage(w, h: Integer; level0: Boolean; chanBase: Integer; out px: TImage): Boolean;
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
    usePrev: Boolean; lastLp, lastDp: Integer;
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
  pos := 0; x := 0; y := 0; lastType := 0; lastLp := 0; lastDp := 0; argb := 0;
  while (pos < total) and not fail do begin
    if metaBits > 0 then g := meta[SizeInt(y shr metaBits) * mw + (x shr metaBits)] else g := 0;
    { the green symbol: a literal, a copy's length prefix, or a cache index;
      coded as its type first, then the value }
    if mode <> MODE_DEC then begin
      s := ReadSym(codes[g][0]);
      if fail then Break;
      if s < 256 then t := 0 else if s < 280 then t := 1 else t := 2;
      { the type: a symbol of its own, unless the code allows only one }
    end else begin s := 0; t := 0; end;
    if codes[g][0].single < 0 then begin
      if mode = MODE_ENC then st.bm.Code(cd, t, 2, K_TYPE + 64 * Ord(level0), lastType, 0)
      else if mode = MODE_DEC then t := st.bm.Code(cd, 0, 2, K_TYPE + 64 * Ord(level0), lastType, 0);
    end else if mode = MODE_DEC then begin
      s := codes[g][0].single;
      if s < 256 then t := 0 else if s < 280 then t := 1 else t := 2;
    end;
    lastType := t;
    { the neighbourhood }
    for k := 1 to 8 do c[k] := NONE;
    case t of
      0: begin
        { green, red, blue, alpha; each with its neighbours in this image }
        for k := 0 to 3 do begin
          i := CHAN_BYTE[k];                      { the channel's byte in ARGB }
          c[0] := chanBase + k;
          if x > 0 then c[1] := Ch(pos - 1, i) else c[1] := NONE;
          if y > 0 then begin
            c[2] := Ch(pos - w, i);
            if x > 0 then c[3] := Ch(pos - w - 1, i) else c[3] := NONE;
            if x + 1 < w then c[4] := Ch(pos - w + 1, i) else c[4] := NONE;
          end else begin c[2] := NONE; c[3] := NONE; c[4] := NONE; end;
          if usePrev then c[5] := (prevPx[pos] shr (8 * i)) and 255 else c[5] := NONE;
          if (c[1] <> NONE) and (c[2] <> NONE) and (c[3] <> NONE) then c[6] := Clip(c[1] + c[2] - c[3])
          else if c[1] <> NONE then c[6] := c[1] else c[6] := c[2];
          if k > 0 then begin
            c[7] := (argb shr 8) and 255;          { this pixel's green }
            if x > 0 then c[8] := Clip(Ch(pos - 1, i) - Ch(pos - 1, 1) + 128) else c[8] := NONE;
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
      end;
      3: begin
        size := wk.Field(8, K_TRANS, 19) + 1;
        if not wk.DecodeImage(size, 1, False, 4, sub) then Exit;
        if size > 16 then bits := 0 else if size > 4 then bits := 1
        else if size > 2 then bits := 2 else bits := 3;
        xs := DivRound(xs, 1 shl bits);
      end;
    end;
  end;
  if wk.fail then Exit;
  if not wk.DecodeImage(xs, h, True, 0, main) then Exit;
  mainW := xs; mainH := h;
  Result := True;
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

procedure Add(const d: TBytes; var r: TWebpStreams; var n: Integer; a, b: SizeInt;
              sub, w, h: Integer);
var s: TWebpStream;
begin
  if b - a < 1 then Exit;
  s.dataStart := a; s.dataEnd := b; s.sub := sub; s.width := w; s.height := h;
  if not CheckStream(d, s) then Exit;
  if n >= Length(r) then SetLength(r, n * 2 + 8);
  r[n] := s; Inc(n);
end;

procedure Walk(const d: TBytes; q, stop: SizeInt; fw, fh: Integer; var r: TWebpStreams;
               var n: Integer; depth: Integer);
var sz: SizeInt;
begin
  while q + 8 <= stop do begin
    sz := Le32(d, q + 4);
    if q + 8 + sz > stop then Exit;
    if IsId(d, q, 'VP8X') and (sz >= 10) then begin
      fw := Le24(d, q + 12) + 1; fh := Le24(d, q + 15) + 1;
    end else if IsId(d, q, 'ANMF') and (sz >= 16) and (depth = 0) then
      Walk(d, q + 8 + 16, q + 8 + sz, Le24(d, q + 14) + 1, Le24(d, q + 17) + 1, r, n, 1)
    else if IsId(d, q, 'VP8L') then
      Add(d, r, n, q + 8, q + 8 + sz, WK_VP8L, 0, 0)
    else if IsId(d, q, 'ALPH') and (sz >= 2) and ((d[q + 8] and 3) = 1) and (fw > 0) then
      Add(d, r, n, q + 9, q + 8 + sz, WK_ALPH, fw, fh);
    q := q + 8 + sz + (sz and 1);
  end;
end;

function FindWebpStreams(const d: TBytes): TWebpStreams;
var n: Integer; stop: SizeInt;
begin
  Result := nil; n := 0;
  if (Length(d) < 12) or not IsId(d, 0, 'RIFF') or not IsId(d, 8, 'WEBP') then Exit;
  stop := 8 + Le32(d, 4);
  if stop > Length(d) then stop := Length(d);
  Walk(d, 12, stop, 0, 0, Result, n, 0);
  SetLength(Result, n);
end;

{ ---------------- coding ---------------- }

procedure CodeWebpStream(cd: TCoder; st: TWebpState; const s: TWebpStream;
                         var data: TBytes; len: SizeInt);
var wk: TWalk;
begin
  wk := Default(TWalk);
  wk.cd := cd; wk.st := st;
  wk.prevPx := st.prev[s.sub].px; wk.prevW := st.prev[s.sub].w; wk.prevH := st.prev[s.sub].h;
  wk.io.len := len;
  if cd.encoding then begin
    wk.mode := MODE_ENC;
    wk.io.d := data;
  end else begin
    wk.mode := MODE_DEC;
    wk.io.d := nil; SetLength(wk.io.d, len);
  end;
  RunWalk(wk, s, len);
  if wk.fail then raise Exception.Create('paiawebp: a stream that does not walk');
  data := wk.io.d;
end;

end.
