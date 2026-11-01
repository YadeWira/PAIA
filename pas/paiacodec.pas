{ The codec stream: a file with GIF images in it, as
    - its bytes without the images' LZW data (headers, palettes,
      extensions, descriptors, and anything that is not GIF), and
    - for each image whose LZW comes back exactly: its pixels and what
      rebuilds the LZW from them (paiagif.TLzwInfo),
  all through one arithmetic coder.

  STREAM (version 1; proof of concept: not frozen)
    version   1 B    1
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

{ The previous image of the same width, for the pixel model. }
function PrevOf(const widths: array of Integer; const pxs: array of TBytes; i: Integer): TBytes;
var j: Integer;
begin
  Result := nil;
  for j := i - 1 downto 0 do
    if widths[j] = widths[i] then Exit(pxs[j]);
end;

{ Both directions in one: the same calls, in the same order. }
procedure CodeAll(cd: TCoder; var raw: TBytes; var tk: TTakenArray; var count: Integer;
                  maxOut: SizeInt);
var bm: TByteModel; pm: TPixelModel; i, j: Integer; cnt, pos, last: QWord;
    widths: array of Integer; pxs: array of TBytes; flags: Integer;
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
  bm := TByteModel.Create;
  pm := TPixelModel.Create;
  try
    rawLen := Bounded(V(Length(raw)), maxOut);
    count := Bounded(V(count), rawLen + 1);
    if not cd.encoding then begin SetLength(raw, rawLen); SetLength(tk, count); end;
    for j := 0 to rawLen - 1 do raw[j] := bm.Code(cd, raw[j], S_RAW);
    widths := nil; pxs := nil;
    SetLength(widths, count); SetLength(pxs, count);
    last := 0;
    for i := 0 to count - 1 do
      with tk[i] do begin
        pos := Bounded(V(Int64(img.dataStart) - Int64(last)), rawLen - last) + last;
        img.dataStart := pos; last := pos;
        img.mcs := Bounded(V(img.mcs), 8);
        if img.mcs < 1 then raise Exception.Create('paiacodec: damaged stream');
        info.mcs := img.mcs;
        img.width := Bounded(V(img.width), 65535);
        n := Bounded(V(n), MAX_PIXELS);
        flags := Ord(info.rules.initClear) + 2 * Ord(info.eoi);
        flags := Bounded(V(flags), 3);
        info.rules.initClear := (flags and 1) <> 0;
        info.eoi := (flags and 2) <> 0;
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
        widths[i] := img.width;
        pm.CodeImage(cd, px, n, img.width, img.mcs, PrevOf(widths, pxs, i));
        pxs[i] := px;
      end;
  finally
    pm.Free;
    bm.Free;
  end;
end;

function Compress(const d: TBytes; out stats: TCodecStats): TBytes;
var imgs: TGifImages; tk: TTakenArray; raw, body: TBytes; i, count: Integer;
    q, o: SizeInt; cd: TCoder; t: TTaken;
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

  cd := TCoder.CreateEncoder;
  try
    CodeAll(cd, raw, tk, count, Length(d));
    body := cd.enc.Finish;
  finally
    cd.Free;
  end;
  Result := nil;
  SetLength(Result, Length(body) + 1);
  Result[0] := STREAM_VERSION;
  if Length(body) > 0 then Move(body[0], Result[1], Length(body));
end;

function Decompress(const s: TBytes; maxOut: SizeInt): TBytes;
var tk: TTakenArray; raw, data: TBytes; i, count: Integer; cd: TCoder;
    total, o, q: SizeInt;
begin
  if (Length(s) < 1) or (s[0] <> STREAM_VERSION) then
    raise Exception.Create('paiacodec: unknown stream version');
  raw := nil; count := 0;
  cd := TCoder.CreateDecoder(s, 1, Length(s) - 1);
  try
    tk := nil; count := 0;
    CodeAll(cd, raw, tk, count, maxOut);
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
