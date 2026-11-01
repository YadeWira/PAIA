{ GIF: finding the images in a file, and taking their LZW apart so that it can
  be rebuilt bit for bit from the pixels.

  An LZW stream is a sequence of codes. Given the pixels, a GIF encoder has
  little freedom: almost all of them emit, at every step, the longest string
  already in the dictionary (greedy matching), so the codes follow from the
  pixels. What an encoder does choose:
    - whether it starts with a clear code;
    - when it clears a full (or not yet full) dictionary;
    - rarely, a shorter match than the longest one;
    - whether it ends with the end code, what goes in the unused bits of the
      last byte, and anything left after the end;
    - how it cuts the data into sub-blocks (almost always 255 bytes each).
  The first two are rules (TLzwRules); a code the rules do not predict is an
  exception, stored with its position; the rest is stored as it is. So ANY
  LZW stream comes back exactly: one from an unusual encoder just costs
  more exceptions. And it is checked: Analyse rebuilds the stream and
  compares it with the original before accepting it. }
unit paiagif;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiagif: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiagif: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

const
  { Pixels one image may decode to: an LZW stream can expand 4,000x, and a
    small file must not claim gigabytes. 64 Mpixels covers 8K x 8K. }
  MAX_PIXELS = SizeInt(1) shl 26;

type
  TIntArray = array of LongInt;

  { An image found in the file: where its LZW data is, and what the pixel
    model needs from its descriptor. }
  TGifImage = record
    mcsPos: SizeInt;        { the byte with the minimum code size }
    dataStart: SizeInt;     { the first sub-block's length byte }
    dataEnd: SizeInt;       { just after the terminating empty sub-block }
    mcs: Integer;
    width, height: Integer;
    interlaced: Boolean;
  end;
  TGifImages = array of TGifImage;

  TLzwRules = record
    initClear: Boolean;     { a clear code first }
    clearAt: Integer;       { a clear when the dictionary's next code is this; 0: never }
  end;

  { Everything that, with the pixels, rebuilds an image's data bytes (the
    sub-blocks with their length bytes and the terminator). }
  TLzwInfo = record
    mcs: Integer;
    rules: TLzwRules;
    excK, excCode: TIntArray;   { exception k: code number k is excCode }
    eoi: Boolean;               { ends with the end code }
    padBits: Integer;           { the unused high bits of the last code's byte }
    trailing: TBytes;           { the bytes after it }
    chunk: Integer;             { sub-blocks of `chunk` bytes, the last shorter; 0: list }
    blockLens: TIntArray;       { with chunk = 0: every sub-block's length }
  end;

{ The images of every GIF stream in d (a file may hold several, or a GIF
  after a MacBinary or other header). Only images whose sub-blocks are
  complete are returned; the rest of the file stays as bytes. }
function FindGifImages(const d: TBytes): TGifImages;

{ Decodes and checks: True if the image's data region comes back byte for
  byte from px[0..n) and info. }
function Analyse(const d: TBytes; const img: TGifImage; out px: TBytes;
                 out n: SizeInt; out info: TLzwInfo): Boolean;

{ The data region (sub-blocks and terminator) from the pixels and info. }
function Rebuild(const px: TBytes; n: SizeInt; const info: TLzwInfo): TBytes;

implementation

const
  MAX_CODES = 4096;

{ ---------------- finding images ---------------- }

{ Skips sub-blocks from q; returns the position after the terminator, or -1
  if they run past the end. }
function SkipBlocks(const d: TBytes; q: SizeInt): SizeInt;
var len: SizeInt;
begin
  len := Length(d);
  while True do begin
    if q >= len then Exit(-1);
    if d[q] = 0 then Exit(q + 1);
    q := q + 1 + d[q];
  end;
end;

function IsSignature(const d: TBytes; p: SizeInt): Boolean;
begin
  Result := (p + 6 <= Length(d)) and (d[p] = Ord('G')) and (d[p + 1] = Ord('I'))
    and (d[p + 2] = Ord('F')) and (d[p + 3] = Ord('8'))
    and ((d[p + 4] = Ord('7')) or (d[p + 4] = Ord('9'))) and (d[p + 5] = Ord('a'));
end;

function FindGifImages(const d: TBytes): TGifImages;
var pos, q, len, e: SizeInt; n: Integer; flags: Byte; img: TGifImage; ok: Boolean;
begin
  Result := nil; n := 0;
  len := Length(d);
  pos := 0;
  while pos < len do begin
    while (pos < len) and not IsSignature(d, pos) do Inc(pos);
    if pos >= len then Break;
    q := pos + 13;
    if q > len then Break;
    flags := d[pos + 10];
    if (flags and $80) <> 0 then q := q + 3 * (SizeInt(2) shl (flags and 7));
    ok := True;
    while ok do begin
      if q >= len then begin ok := False; Break; end;
      case d[q] of
        $21: begin
          if q + 2 > len then begin ok := False; Break; end;
          e := SkipBlocks(d, q + 2);
          if e < 0 then begin ok := False; Break; end;
          q := e;
        end;
        $2C: begin
          if q + 11 > len then begin ok := False; Break; end;
          img.width := d[q + 5] or (d[q + 6] shl 8);
          img.height := d[q + 7] or (d[q + 8] shl 8);
          flags := d[q + 9];
          img.interlaced := (flags and $40) <> 0;
          q := q + 10;
          if (flags and $80) <> 0 then q := q + 3 * (SizeInt(2) shl (flags and 7));
          if q + 1 > len then begin ok := False; Break; end;
          img.mcsPos := q;
          img.mcs := d[q];
          img.dataStart := q + 1;
          e := SkipBlocks(d, q + 1);
          if e < 0 then begin ok := False; Break; end;
          img.dataEnd := e;
          if (img.mcs >= 1) and (img.mcs <= 8) then begin
            if n >= Length(Result) then SetLength(Result, n * 2 + 8);
            Result[n] := img; Inc(n);
          end;
          q := e;
        end;
        $3B: begin q := q + 1; Break; end;
      else
        Break;    { not a block: this stream ends here }
      end;
    end;
    if q <= pos then q := pos + 1;
    pos := q;
    if not ok then Break;
  end;
  SetLength(Result, n);
end;

{ ---------------- the LZW machine ---------------- }

type
  { The dictionary as the decoder keeps it, with a lookup (prefix, char) ->
    code for the greedy predictions. The lookup is reset by a generation
    stamp, so that a clear does not cost a 1M-entry wipe. }
  TLzw = record
    mcs, clear, eoiCode, next, width, prev: Integer;
    prefix, first, len: array[0..MAX_CODES - 1] of LongInt;
    suffix: array[0..MAX_CODES - 1] of Byte;
    stamp: array of Word;
    val: array of Word;
    gen: Word;
    procedure Init(aMcs: Integer);
    procedure Reset;
    function Lookup(pre, c: Integer): Integer; inline;
    { Applies one code (not the end code); False if invalid. }
    function Apply(c: Integer; out firstChar, strLen: Integer): Boolean;
  end;

procedure TLzw.Init(aMcs: Integer);
var i: Integer;
begin
  mcs := aMcs;
  clear := 1 shl mcs;
  eoiCode := clear + 1;
  for i := 0 to clear - 1 do begin
    prefix[i] := -1; suffix[i] := i; first[i] := i; len[i] := 1;
  end;
  stamp := nil; val := nil;
  SetLength(stamp, MAX_CODES * 256);
  SetLength(val, MAX_CODES * 256);
  gen := 1;
  Reset;
  gen := 1;
end;

procedure TLzw.Reset;
begin
  next := clear + 2;
  width := mcs + 1;
  prev := -1;
  if gen = High(Word) then begin
    FillChar(stamp[0], Length(stamp) * SizeOf(Word), 0);
    gen := 1;
  end else Inc(gen);
end;

function TLzw.Lookup(pre, c: Integer): Integer; inline;
var key: SizeInt;
begin
  key := (SizeInt(pre) shl 8) or c;
  if stamp[key] = gen then Result := val[key] else Result := -1;
end;

function TLzw.Apply(c: Integer; out firstChar, strLen: Integer): Boolean;
var key: SizeInt;
begin
  firstChar := 0; strLen := 0;
  if c = clear then begin Reset; Exit(True); end;
  if c < clear then begin firstChar := c; strLen := 1; end
  else if (c > eoiCode) and (c < next) then begin firstChar := first[c]; strLen := len[c]; end
  else if (c = next) and (prev >= 0) and (next < MAX_CODES) then begin
    firstChar := first[prev]; strLen := len[prev] + 1;
  end else Exit(False);
  if (prev >= 0) and (next < MAX_CODES) then begin
    prefix[next] := prev; suffix[next] := firstChar;
    first[next] := first[prev]; len[next] := len[prev] + 1;
    key := (SizeInt(prev) shl 8) or firstChar;
    if stamp[key] <> gen then begin stamp[key] := gen; val[key] := next; end;
    Inc(next);
    if (next = (1 shl width)) and (width < 12) then Inc(width);
  end;
  prev := c;
  Result := True;
end;

{ The code the rules and greedy matching predict at pixel pos, for the k-th
  code; -1: none (the pixels are all coded). }
function Predict(var z: TLzw; const px: TBytes; n, pos: SizeInt; k: SizeInt;
                 const rules: TLzwRules): Integer;
var s, c, t: Integer; p: SizeInt; pend: Boolean;
begin
  if (k = 0) and rules.initClear then Exit(z.clear);
  if pos >= n then Exit(-1);
  if (rules.clearAt > 0) and (z.next = rules.clearAt) then Exit(z.clear);
  s := px[pos];
  { the entry the encoder already has and the decoder not yet: the previous
    string plus this one's first pixel }
  pend := (z.prev >= 0) and (z.next < MAX_CODES);
  p := pos + 1;
  while p < n do begin
    c := px[p];
    t := z.Lookup(s, c);
    if (t < 0) and pend and (s = z.prev) and (c = px[pos]) then t := z.next;
    if t < 0 then Break;
    s := t;
    Inc(p);
  end;
  Result := s;
end;

{ ---------------- bits ---------------- }

type
  TBitWriter = record
    d: TBytes;
    n: SizeInt;
    acc: QWord;
    bits: Integer;
    procedure Init;
    procedure Put(v: LongWord; w: Integer); inline;
    { the unused high bits of the last byte, then everything out }
    procedure Flush(pad: Integer);
  end;

procedure TBitWriter.Init;
begin
  d := nil; SetLength(d, 4096); n := 0; acc := 0; bits := 0;
end;

procedure TBitWriter.Put(v: LongWord; w: Integer); inline;
begin
  acc := acc or (QWord(v) shl bits);
  bits := bits + w;
  while bits >= 8 do begin
    if n >= Length(d) then SetLength(d, Length(d) * 2);
    d[n] := Byte(acc); Inc(n);
    acc := acc shr 8; bits := bits - 8;
  end;
end;

procedure TBitWriter.Flush(pad: Integer);
begin
  if bits > 0 then begin
    if n >= Length(d) then SetLength(d, Length(d) * 2);
    d[n] := Byte(acc or (QWord(pad) shl bits)); Inc(n);
    acc := 0; bits := 0;
  end;
  SetLength(d, n);
end;

{ ---------------- analysis ---------------- }

{ The sub-blocks' payload, concatenated, and their lengths. }
procedure Gather(const d: TBytes; const img: TGifImage; out data: TBytes;
                 out lens: TIntArray);
var q, total: SizeInt; nb: Integer;
begin
  data := nil; lens := nil;
  total := 0; nb := 0;
  q := img.dataStart;
  while d[q] <> 0 do begin
    total := total + d[q]; Inc(nb); q := q + 1 + d[q];
  end;
  SetLength(data, total);
  SetLength(lens, nb);
  total := 0; nb := 0;
  q := img.dataStart;
  while d[q] <> 0 do begin
    lens[nb] := d[q]; Inc(nb);
    if d[q] > 0 then Move(d[q + 1], data[total], d[q]);
    total := total + d[q]; q := q + 1 + d[q];
  end;
end;

{ Counts (and with keep, records) the exceptions to `rules` of the code
  sequence; -1 if the sequence is not one the machine accepts. }
function Exceptions(const px: TBytes; n: SizeInt; mcs: Integer;
                    const codes: TIntArray; nCodes: SizeInt; const rules: TLzwRules;
                    keep: Boolean; var excK, excCode: TIntArray): SizeInt;
var z: TLzw; k, pos: SizeInt; pred, c, f, l: Integer;
begin
  z.Init(mcs);
  Result := 0;
  pos := 0;
  for k := 0 to nCodes - 1 do begin
    c := codes[k];
    pred := Predict(z, px, n, pos, k, rules);
    if pred <> c then begin
      if keep then begin
        if Result >= Length(excK) then begin
          SetLength(excK, Result * 2 + 16); SetLength(excCode, Result * 2 + 16);
        end;
        excK[Result] := k; excCode[Result] := c;
      end;
      Inc(Result);
    end;
    if not z.Apply(c, f, l) then Exit(-1);
    pos := pos + l;
  end;
  if keep then begin SetLength(excK, Result); SetLength(excCode, Result); end;
end;

function Analyse(const d: TBytes; const img: TGifImage; out px: TBytes;
                 out n: SizeInt; out info: TLzwInfo): Boolean;
var data, back: TBytes; lens: TIntArray; z: TLzw;
    bitPos, totalBits: Int64; codes, cand, candCount: TIntArray;
    nCodes, i, j, best, cnt: SizeInt; c, f, l, w, nb: Integer; code: LongWord;
    r: TLzwRules; dummyK, dummyC: TIntArray;
    q, p: SizeInt;
begin
  Result := False;
  px := nil; n := 0;
  info := Default(TLzwInfo);
  info.mcs := img.mcs;
  Gather(d, img, data, lens);

  { 1. decode, keeping the codes }
  z.Init(img.mcs);
  totalBits := Int64(Length(data)) * 8;
  bitPos := 0;
  codes := nil; SetLength(codes, 1024); nCodes := 0;
  SetLength(px, 4096);
  info.eoi := False;
  while True do begin
    w := z.width;
    if bitPos + w > totalBits then Break;
    code := 0;
    for i := 0 to w - 1 do
      if (data[(bitPos + i) shr 3] shr ((bitPos + i) and 7)) and 1 <> 0 then
        code := code or (LongWord(1) shl i);
    c := code;
    if c = z.eoiCode then begin info.eoi := True; bitPos := bitPos + w; Break; end;
    { the string, before Apply changes prev }
    if not z.Apply(c, f, l) then Break;
    if c <> z.clear then begin
      if n + l > MAX_PIXELS then Exit(False);
      while n + l > Length(px) do SetLength(px, Length(px) * 2);
      { write the string backwards: c's chain, or for the new code its
        prefix's chain and the first char }
      j := c; p := n + l - 1;
      while (j >= z.clear) do begin
        px[p] := z.suffix[j]; Dec(p); j := z.prefix[j];
      end;
      px[p] := j;
      n := n + l;
    end;
    if nCodes >= Length(codes) then SetLength(codes, nCodes * 2);
    codes[nCodes] := c; Inc(nCodes);
    bitPos := bitPos + w;
  end;
  SetLength(px, n);

  { 2. the rules that leave the fewest exceptions }
  r.initClear := (nCodes > 0) and (codes[0] = z.clear);
  cand := nil; candCount := nil;
  { the dictionary's next code at each clear but a first one }
  z.Init(img.mcs);
  for i := 0 to nCodes - 1 do begin
    if (codes[i] = z.clear) and (i > 0) and (z.next > z.clear + 2) then begin
      j := 0;
      while (j < Length(cand)) and (cand[j] <> z.next) do Inc(j);
      if j = Length(cand) then begin
        SetLength(cand, j + 1); SetLength(candCount, j + 1);
        cand[j] := z.next; candCount[j] := 0;
      end;
      Inc(candCount[j]);
    end;
    if not z.Apply(codes[i], f, l) then Break;
  end;
  r.clearAt := 0;
  dummyK := nil; dummyC := nil;
  best := Exceptions(px, n, img.mcs, codes, nCodes, r, False, dummyK, dummyC);
  if best < 0 then Exit(False);
  info.rules := r;
  { the three most frequent candidates }
  for j := 0 to 2 do begin
    nb := -1; cnt := 0;
    for i := 0 to High(cand) do
      if candCount[i] > cnt then begin cnt := candCount[i]; nb := i; end;
    if nb < 0 then Break;
    candCount[nb] := 0;
    r.clearAt := cand[nb];
    i := Exceptions(px, n, img.mcs, codes, nCodes, r, False, dummyK, dummyC);
    if (i >= 0) and (i < best) then begin best := i; info.rules := r; end;
  end;
  Exceptions(px, n, img.mcs, codes, nCodes, info.rules, True, info.excK, info.excCode);

  { 3. what follows the last code }
  q := bitPos shr 3;
  if (bitPos and 7) <> 0 then begin
    info.padBits := data[q] shr (bitPos and 7);
    Inc(q);
  end else info.padBits := 0;
  info.trailing := Copy(data, q, Length(data) - q);

  { 4. the sub-blocks }
  info.chunk := 0;
  if Length(lens) = 0 then info.chunk := 255
  else begin
    info.chunk := lens[0];
    for i := 0 to High(lens) - 1 do
      if lens[i] <> info.chunk then info.chunk := 0;
    if (info.chunk > 0) and (lens[High(lens)] > info.chunk) then info.chunk := 0;
  end;
  if info.chunk = 0 then info.blockLens := lens else info.blockLens := nil;

  { 5. rebuild and compare }
  back := Rebuild(px, n, info);
  if Length(back) <> img.dataEnd - img.dataStart then Exit(False);
  if (Length(back) > 0) and not CompareMem(@back[0], @d[img.dataStart], Length(back)) then
    Exit(False);
  Result := True;
end;

{ ---------------- rebuilding ---------------- }

function Rebuild(const px: TBytes; n: SizeInt; const info: TLzwInfo): TBytes;
var z: TLzw; bw: TBitWriter; k, pos, ei: SizeInt; c, f, l, i: Integer;
    data: TBytes; q, total, o, b: SizeInt;
begin
  z.Init(info.mcs);
  bw.Init;
  k := 0; pos := 0; ei := 0;
  while True do begin
    if (ei < Length(info.excK)) and (info.excK[ei] = k) then begin
      c := info.excCode[ei]; Inc(ei);
    end else begin
      c := Predict(z, px, n, pos, k, info.rules);
      if c < 0 then Break;
    end;
    bw.Put(c, z.width);
    if not z.Apply(c, f, l) then
      raise Exception.Create('paiagif: an invalid code to rebuild');
    pos := pos + l;
    Inc(k);
    if pos > n then raise Exception.Create('paiagif: codes past the pixels');
  end;
  if info.eoi then bw.Put(z.eoiCode, z.width);
  bw.Flush(info.padBits);
  data := bw.d;
  total := Length(data) + Length(info.trailing);

  { into sub-blocks }
  Result := nil;
  if info.chunk > 0 then begin
    SetLength(Result, total + (total + info.chunk - 1) div info.chunk + 1);
  end else begin
    b := 0;
    for i := 0 to High(info.blockLens) do b := b + info.blockLens[i];
    if b <> total then raise Exception.Create('paiagif: sub-blocks do not add up');
    SetLength(Result, total + Length(info.blockLens) + 1);
  end;
  o := 0; q := 0; i := 0;
  while q < total do begin
    if info.chunk > 0 then begin
      b := info.chunk; if total - q < b then b := total - q;
    end else begin
      b := info.blockLens[i]; Inc(i);
    end;
    Result[o] := b; Inc(o);
    for k := 0 to b - 1 do begin
      if q + k < Length(data) then Result[o + k] := data[q + k]
      else Result[o + k] := info.trailing[q + k - Length(data)];
    end;
    o := o + b; q := q + b;
  end;
  Result[o] := 0; Inc(o);
  SetLength(Result, o);
end;

end.
