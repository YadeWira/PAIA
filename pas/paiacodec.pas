{ The codec stream: a file with GIF images in it, as
    - its bytes without the images' LZW data (headers, palettes,
      extensions, descriptors, and anything that is not GIF), and
    - for each image whose LZW comes back exactly: its pixels and what
      rebuilds the LZW from them (paiagif.TLzwInfo),
  all through one arithmetic coder.

  STREAM (version 1; proof of concept: not frozen)
    version   1 B    1
    tables    2 B    log2 of the byte model's and the pixel model's tables
                     (12 to 22: from the sizes, so a small file clears little)
    coded     the rest:
      varint  raw length
      varint  image count
      raw     the bytes
      per image:
        varint  where its data goes in the raw bytes, from the previous one
        varint  mcs, width, pixel count
        varint  flags: bit 0 starts with a clear, bit 1 ends with the end code
        varint  clearAt, padBits
        varint  exception count; per exception: k from the previous, code
        varint  trailing length, and the bytes
        varint  chunk; if 0: the sub-block count and every length
        pixels  (TPixelModel), the previous frame being the last image of
                the same width }
unit paiacodec;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiacodec: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiacodec: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith, paiamodel, paiagif;

const
  STREAM_VERSION = 1;

type
  TCodecStats = record
    images, imagesTaken: Integer;
    lzwBytes: SizeInt;      { the LZW data of the images taken }
    pixels: SizeInt;
    exceptions: SizeInt;
  end;

{ The codec stream of d. }
function Compress(const d: TBytes; out stats: TCodecStats): TBytes;
{ The original from a stream, at most maxOut bytes; raises on a damaged
  stream (the caller also checks size and hash). }
function Decompress(const s: TBytes; maxOut: SizeInt): TBytes;

implementation

const
  S_RAW = 0;
  S_AUX = 1;

type
  TTaken = record
    img: TGifImage;
    px: TBytes;
    n: SizeInt;
    info: TLzwInfo;
  end;
  TTakenArray = array of TTaken;

{ The canvas of one GIF stream, as a viewer composes it image after image:
  what the pixel model sees under each pixel, and the previous image at
  the same place. Both sides build it the same way, from pixels already
  coded. }
type
  TCanvas = class
    cw, ch: Integer;
    c: TWords;                       { 256: never painted, or cleared }
    has: Boolean;                    { a previous image }
    pl, pt, pwid, phei, pdisp, ptransp: Integer;
    grid: TWords;                    { the previous image, rows in place }
    saved: TWords;                   { for disposal 3: the canvas under it }
    constructor Create(aw, ah: Integer);
    { before an image: the previous one's disposal; then the contexts }
    procedure Contexts(const img: TGifImage; n: SizeInt; out cv, pw: TWords);
    procedure Paint(const img: TGifImage; const px: TBytes; n: SizeInt);
  end;

{ the row in the image of the r-th row of the data (interlaced: rows 0, 8,
  16..., then 4, 12..., then 2, 6..., then the odd ones) }
function RowMap(h: Integer; interlaced: Boolean): TIntArray;
const start: array[0..3] of Integer = (0, 4, 2, 1);
      step: array[0..3] of Integer = (8, 8, 4, 2);
var k, y, r: Integer;
begin
  Result := nil; SetLength(Result, h);
  if not interlaced then begin
    for r := 0 to h - 1 do Result[r] := r;
    Exit;
  end;
  r := 0;
  for k := 0 to 3 do begin
    y := start[k];
    while y < h do begin Result[r] := y; Inc(r); y := y + step[k]; end;
  end;
end;

constructor TCanvas.Create(aw, ah: Integer);
var i: SizeInt;
begin
  inherited Create;
  cw := aw; ch := ah;
  c := nil;
  if (cw > 0) and (ch > 0) and (SizeInt(cw) * ch <= MAX_PIXELS) then begin
    SetLength(c, SizeInt(cw) * ch);
    for i := 0 to High(c) do c[i] := 256;
  end;
  has := False;
end;

procedure TCanvas.Contexts(const img: TGifImage; n: SizeInt; out cv, pw: TWords);
var w, x, y, r, cx, cy, qx, qy: Integer; rows: TIntArray; i: SizeInt; v: Word;
begin
  cv := nil; pw := nil;
  if c = nil then Exit;
  { the previous image's disposal }
  if has and ((pdisp = 2) or (pdisp = 3)) then begin
    i := 0;
    for y := pt to pt + phei - 1 do
      for x := pl to pl + pwid - 1 do begin
        if (x < cw) and (y < ch) then begin
          if pdisp = 2 then c[SizeInt(y) * cw + x] := 256
          else if saved <> nil then c[SizeInt(y) * cw + x] := saved[i];
        end;
        Inc(i);
      end;
  end;
  w := img.width; if w < 1 then Exit;
  rows := RowMap(img.height, img.interlaced);
  SetLength(cv, n); SetLength(pw, n);
  x := 0; r := 0;
  for i := 0 to n - 1 do begin
    cv[i] := 256; pw[i] := 256;
    if r < img.height then begin
      cx := img.left + x; cy := img.top + rows[r];
      if (cx < cw) and (cy < ch) then cv[i] := c[SizeInt(cy) * cw + cx];
      if has then begin
        qx := cx - pl; qy := cy - pt;
        if (qx >= 0) and (qy >= 0) and (qx < pwid) and (qy < phei) then begin
          v := grid[SizeInt(qy) * pwid + qx];
          if (v < 256) and (v = ptransp) then pw[i] := 257 else pw[i] := v;
        end;
      end;
    end;
    Inc(x);
    if x = w then begin x := 0; Inc(r); end;
  end;
end;

procedure TCanvas.Paint(const img: TGifImage; const px: TBytes; n: SizeInt);
var w, x, y, r, cx, cy: Integer; rows: TIntArray; i: SizeInt;
begin
  if c = nil then Exit;
  w := img.width; if w < 1 then w := 1;
  { what disposal 3 will put back }
  saved := nil;
  if img.disposal = 3 then begin
    SetLength(saved, SizeInt(img.width) * img.height);
    i := 0;
    for y := img.top to img.top + img.height - 1 do
      for x := img.left to img.left + img.width - 1 do begin
        if (x < cw) and (y < ch) then saved[i] := c[SizeInt(y) * cw + x] else saved[i] := 256;
        Inc(i);
      end;
  end;
  grid := nil;
  SetLength(grid, SizeInt(img.width) * img.height);
  for i := 0 to High(grid) do grid[i] := 256;
  rows := RowMap(img.height, img.interlaced);
  x := 0; r := 0;
  for i := 0 to n - 1 do begin
    if r >= img.height then Break;
    if x < img.width then begin
      grid[SizeInt(rows[r]) * img.width + x] := px[i];
      cx := img.left + x; cy := img.top + rows[r];
      if (cx < cw) and (cy < ch) and not ((img.transparent >= 0) and (px[i] = img.transparent)) then
        c[SizeInt(cy) * cw + cx] := px[i];
    end;
    Inc(x);
    if x = w then begin x := 0; Inc(r); end;
  end;
  has := True;
  pl := img.left; pt := img.top; pwid := img.width; phei := img.height;
  pdisp := img.disposal; ptransp := img.transparent;
end;

{ Both directions in one: the same calls, in the same order. }
procedure CodeAll(cd: TCoder; var raw: TBytes; var tk: TTakenArray; var count: Integer;
                  maxOut: SizeInt; byteBits, pixelBits: Integer);
var bm: TByteModel; pm: TPixelModel; i, j: Integer; cnt, pos, last: QWord;
    flags: Integer; canvas: TCanvas; cv, pw: TWords; newStream: Boolean;
    rawLen: SizeInt;
  { the value when encoding; when decoding, whatever was decoded }
  function V(x: Int64): QWord;
  begin
    if not cd.encoding then x := 0;
    if x < 0 then raise Exception.Create('paiacodec: negative value');
    Result := bm.CodeVarint(cd, x, S_AUX);
  end;
  function Bounded(x: QWord; hi: QWord): SizeInt;
  begin
    if x > hi then raise Exception.Create('paiacodec: damaged stream');
    Result := x;
  end;
begin
  canvas := nil;
  bm := TByteModel.Create(byteBits);
  pm := TPixelModel.Create(pixelBits);
  try
    rawLen := Bounded(V(Length(raw)), maxOut);
    count := Bounded(V(count), rawLen + 1);
    if not cd.encoding then begin SetLength(raw, rawLen); SetLength(tk, count); end;
    for j := 0 to rawLen - 1 do raw[j] := bm.Code(cd, raw[j], S_RAW);
    last := 0;
    for i := 0 to count - 1 do
      with tk[i] do begin
        pos := Bounded(V(Int64(img.dataStart) - Int64(last)), rawLen - last) + last;
        img.dataStart := pos; last := pos;
        img.mcs := Bounded(V(img.mcs), 8);
        if img.mcs < 1 then raise Exception.Create('paiacodec: damaged stream');
        info.mcs := img.mcs;
        img.width := Bounded(V(img.width), 65535);
        img.height := Bounded(V(img.height), 65535);
        img.left := Bounded(V(img.left), 65535);
        img.top := Bounded(V(img.top), 65535);
        img.transparent := Integer(Bounded(V(img.transparent + 1), 256)) - 1;
        img.disposal := Bounded(V(img.disposal), 7);
        n := Bounded(V(n), MAX_PIXELS);
        newStream := (i = 0) or (cd.encoding and (img.stream <> tk[i - 1].img.stream));
        flags := Ord(info.rules.initClear) + 2 * Ord(info.eoi) + 4 * Ord(newStream)
               + 8 * Ord(img.interlaced);
        flags := Bounded(V(flags), 15);
        info.rules.initClear := (flags and 1) <> 0;
        info.eoi := (flags and 2) <> 0;
        newStream := (flags and 4) <> 0;
        img.interlaced := (flags and 8) <> 0;
        if newStream then begin
          img.canvasW := Bounded(V(img.canvasW), 65535);
          img.canvasH := Bounded(V(img.canvasH), 65535);
          canvas.Free;
          canvas := TCanvas.Create(img.canvasW, img.canvasH);
        end;
        if canvas = nil then raise Exception.Create('paiacodec: damaged stream');
        info.rules.clearAt := Bounded(V(info.rules.clearAt), 4096);
        info.padBits := Bounded(V(info.padBits), 255);
        cnt := Bounded(V(Length(info.excK)), MAX_PIXELS + 1);
        if not cd.encoding then begin
          SetLength(info.excK, cnt); SetLength(info.excCode, cnt);
        end;
        last := 0;
        for j := 0 to High(info.excK) do begin
          info.excK[j] := Bounded(V(Int64(info.excK[j]) - Int64(last)), MAX_PIXELS + 1) + last;
          last := info.excK[j];
          info.excCode[j] := Bounded(V(info.excCode[j]), 4095);
        end;
        last := pos;
        cnt := Bounded(V(Length(info.trailing)), maxOut);
        if not cd.encoding then SetLength(info.trailing, cnt);
        for j := 0 to High(info.trailing) do info.trailing[j] := bm.Code(cd, info.trailing[j], S_AUX);
        info.chunk := Bounded(V(info.chunk), 255);
        if info.chunk = 0 then begin
          cnt := Bounded(V(Length(info.blockLens)), maxOut);
          if not cd.encoding then SetLength(info.blockLens, cnt);
          for j := 0 to High(info.blockLens) do
            info.blockLens[j] := Bounded(V(info.blockLens[j]), 255);
        end;
        if not cd.encoding then SetLength(px, n);
        canvas.Contexts(img, n, cv, pw);
        pm.CodeImage(cd, px, n, img.width, img.mcs, cv, pw, img.transparent);
        canvas.Paint(img, px, n);
      end;
  finally
    canvas.Free;
    pm.Free;
    bm.Free;
  end;
end;

function Compress(const d: TBytes; out stats: TCodecStats): TBytes;
var imgs: TGifImages; tk: TTakenArray; raw, body: TBytes; i, count: Integer;
    q, o: SizeInt; cd: TCoder; t: TTaken; pixels: QWord; byteBits, pixelBits: Integer;
begin
  stats := Default(TCodecStats);
  imgs := FindGifImages(d);
  stats.images := Length(imgs);
  tk := nil; SetLength(tk, Length(imgs));
  count := 0;
  for i := 0 to High(imgs) do begin
    t := Default(TTaken);
    t.img := imgs[i];
    if Analyse(d, t.img, t.px, t.n, t.info) then begin
      tk[count] := t; Inc(count);
      stats.lzwBytes := stats.lzwBytes + (t.img.dataEnd - t.img.dataStart);
      stats.pixels := stats.pixels + t.n;
      stats.exceptions := stats.exceptions + Length(t.info.excK);
    end;
  end;
  stats.imagesTaken := count;
  SetLength(tk, count);

  { the bytes without the images' data; each image's place in them }
  raw := nil; SetLength(raw, Length(d));
  q := 0; o := 0;
  for i := 0 to count - 1 do begin
    Move(d[q], raw[o], tk[i].img.dataStart - q);
    o := o + tk[i].img.dataStart - q;
    q := tk[i].img.dataEnd;
    tk[i].img.dataStart := o;
  end;
  if Length(d) > q then Move(d[q], raw[o], Length(d) - q);
  o := o + Length(d) - q;
  SetLength(raw, o);

  pixels := 0;
  for i := 0 to count - 1 do pixels := pixels + QWord(tk[i].n);
  byteBits := TableBitsFor(Length(raw) + 64 * QWord(count));
  pixelBits := TableBitsFor(pixels);
  cd := TCoder.CreateEncoder;
  try
    CodeAll(cd, raw, tk, count, Length(d), byteBits, pixelBits);
    body := cd.enc.Finish;
  finally
    cd.Free;
  end;
  Result := nil;
  SetLength(Result, Length(body) + 3);
  Result[0] := STREAM_VERSION;
  Result[1] := byteBits;
  Result[2] := pixelBits;
  if Length(body) > 0 then Move(body[0], Result[3], Length(body));
end;

function Decompress(const s: TBytes; maxOut: SizeInt): TBytes;
var tk: TTakenArray; raw, data: TBytes; i, count: Integer; cd: TCoder;
    total, o, q: SizeInt;
begin
  if (Length(s) < 3) or (s[0] <> STREAM_VERSION) then
    raise Exception.Create('paiacodec: unknown stream version');
  if (s[1] < 12) or (s[1] > 22) or (s[2] < 12) or (s[2] > 22) then
    raise Exception.Create('paiacodec: damaged stream');
  raw := nil; count := 0;
  cd := TCoder.CreateDecoder(s, 3, Length(s) - 3);
  try
    tk := nil; count := 0;
    CodeAll(cd, raw, tk, count, maxOut, s[1], s[2]);
  finally
    cd.Free;
  end;

  { rebuild }
  Result := nil;
  SetLength(Result, Length(raw));
  o := 0; q := 0; total := 0;
  for i := 0 to count - 1 do begin
    data := Rebuild(tk[i].px, tk[i].n, tk[i].info);
    total := Length(Result) + Length(data);
    if total > maxOut then raise Exception.Create('paiacodec: output larger than declared');
    SetLength(Result, total);
    Move(raw[q], Result[o], tk[i].img.dataStart - q);
    o := o + tk[i].img.dataStart - q;
    q := tk[i].img.dataStart;
    Move(data[0], Result[o], Length(data));
    o := o + Length(data);
  end;
  if Length(raw) > q then Move(raw[q], Result[o], Length(raw) - q);
  o := o + Length(raw) - q;
  SetLength(Result, o);
end;

end.
