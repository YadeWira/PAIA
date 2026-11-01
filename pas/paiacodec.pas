{ The codec stream: a file with GIF images or FLIC chunks in it, as
    - its bytes without the images' LZW data and the chunks' data
      (headers, palettes, extensions, and anything that is neither), and
    - for each GIF image whose LZW comes back exactly: its pixels and what
      rebuilds the LZW from them (paiagif.TLzwInfo);
    - for each FLIC pixel chunk: its data, coded field by field (paiafli);
    - for each bitmap of an ANI's frames: its rows, coded byte by byte
      (paiadib);
    - for each BODY and method-5 DLTA of an IFF ANIM: its data, coded field
      by field (paiaiff);
    - for each VP8L stream of a WebP (lossless frames, lossless alpha):
      its fields' values (paiawebp);
    - for each VP8 frame of a WebP: its boolean coder's decisions
      (paiavp8),
  all through one arithmetic coder.

  STREAM (version 4; proof of concept: not frozen)
    version   1 B    4
    tables    2 B    log2 of the byte model's and the pixel model's tables
                     (12 to 22: from the sizes, so a small file clears little)
    coded     the rest:
      varint  raw length
      varint  record count
      raw     the bytes
      per record, in file order:
        varint  kind: 0 a GIF image, 1 a FLIC chunk, 2 an ANI bitmap,
                3 an IFF ANIM chunk, 4 a WebP VP8L stream, 5 a WebP VP8 frame
        varint  where its data goes in the raw bytes, from the previous one
        varint  kinds 1 to 5: 0, or how many records back is one of the same
                kind with the same data (then nothing else follows)
      a GIF image:
        varint  mcs, width, height, left, top, transparent + 1, disposal,
                pixel count
        varint  flags: bit 0 starts with a clear, bit 1 ends with the end
                code, bit 2 a new GIF stream (then canvas width and height),
                bit 3 interlaced
        varint  clearAt, padBits
        varint  exception count; per exception: k from the previous, code
        varint  trailing length, and the bytes
        varint  chunk; if 0: the sub-block count and every length
        pixels  (TPixelModel), over the canvas the stream's images compose
      a FLIC chunk:
        varint  a new FLIC (then its width and height)
        varint  chunk type, data length
        data    (paiafli.CodeChunk)
      an ANI bitmap:
        varint  width, height, bits a pixel, data length
        data    (paiadib.CodeDib), the previous bitmap of the same shape
                as context
      an IFF ANIM chunk:
        varint  0 an uncompressed BODY, 1 a ByteRun1 BODY, 2 a method-5 DLTA
        varint  a BODY: width, height, planes (it starts an animation);
                a DLTA: ANHD's interleave, XOR mode
        varint  data length
        data    (paiaiff.CodeIffChunk)
      a WebP VP8L stream:
        varint  0 a VP8L chunk, 1 an ALPH chunk's data (then the frame's
                width and height)
        varint  data length
        data    (paiawebp.CodeWebpStream)
      a WebP VP8 frame:
        varint  data length
        data    (paiavp8.CodeVp8Stream) }
unit paiacodec;

{$I paia.inc}
{$ifdef PAIA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal paiacodec: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal paiacodec: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, paiaarith, paiamodel, paiagif, paiafli, paiadib, paiaiff, paiawebp, paiavp8;

const
  STREAM_VERSION = 4;

type
  TCodecStats = record
    images, imagesTaken: Integer;
    lzwBytes: SizeInt;      { the LZW data of the images taken }
    pixels: SizeInt;
    exceptions: SizeInt;
    fliChunks: Integer;
    dibs: Integer;
    iffChunks: Integer;
    webpStreams: Integer;
    vp8Frames: Integer;
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
    kind: Integer;          { 0: a GIF image; 1: a FLIC chunk; 2: an ANI frame's bitmap;
                              3: an IFF ANIM BODY or DLTA; 4: a WebP VP8L stream;
                              5: a WebP VP8 frame }
    fli: TFliChunk;
    dib: TDib;
    iff: TIffChunk;
    wst: TWebpStream;
    vst: TVp8Stream;
    fdata: TBytes;          { a FLIC chunk's or a bitmap's data }
  end;
  TTakenArray = array of TTaken;

function StartOf(const t: TTaken): SizeInt;
begin
  case t.kind of
    0: Result := t.img.dataStart;
    1: Result := t.fli.dataStart;
    2: Result := t.dib.dataStart;
    3: Result := t.iff.dataStart;
    4: Result := t.wst.dataStart;
  else Result := t.vst.dataStart;
  end;
end;

function EndOf(const t: TTaken): SizeInt;
begin
  case t.kind of
    0: Result := t.img.dataEnd;
    1: Result := t.fli.dataEnd;
    2: Result := t.dib.dataEnd;
    3: Result := t.iff.dataEnd;
    4: Result := t.wst.dataEnd;
  else Result := t.vst.dataEnd;
  end;
end;

procedure SetStart(var t: TTaken; p: SizeInt);
begin
  case t.kind of
    0: t.img.dataStart := p;
    1: t.fli.dataStart := p;
    2: t.dib.dataStart := p;
    3: t.iff.dataStart := p;
    4: t.wst.dataStart := p;
  else t.vst.dataStart := p;
  end;
end;

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
    rawLen, flen: SizeInt; fm: TFliModel; fimg: TFliImage; fliStream, gifStream: Integer;
    dm: TDibModel; prevDib: TBytes; k: Integer;
    itm: TTokenModel; ipm: TDibModel; ist: TAnimState; wstate: TWebpState; dup: Integer; vm: TVp8Model;
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
  canvas := nil; fm := nil; fimg := nil; fliStream := -1; gifStream := -1; dm := nil;
  itm := nil; ipm := nil; ist := nil; wstate := nil; vm := nil;
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
        kind := Bounded(V(kind), 5);
        pos := Bounded(V(Int64(StartOf(tk[i])) - Int64(last)), rawLen - last) + last;
        SetStart(tk[i], pos); last := pos;
        { data the same as an earlier record's of the same kind (a repeated
          frame): only how far back; the models do not see it again }
        if kind >= 1 then begin
          dup := 0;
          if cd.encoding then
            for k := i - 1 downto 0 do begin
              if i - k > 4096 then Break;
              if (tk[k].kind = kind) and (Length(tk[k].fdata) = Length(fdata)) and
                 ((Length(fdata) = 0) or CompareMem(@tk[k].fdata[0], @fdata[0], Length(fdata))) then begin
                dup := i - k; Break;
              end;
            end;
          dup := Bounded(V(dup), i);
          if dup > 0 then begin
            if tk[i - dup].kind <> kind then raise Exception.Create('paiacodec: damaged stream');
            fdata := tk[i - dup].fdata;
            { the same description on both sides (the decoder has only the
              earlier record's), so that what looks back at it agrees }
            fli := tk[i - dup].fli; dib := tk[i - dup].dib;
            iff := tk[i - dup].iff; wst := tk[i - dup].wst; vst := tk[i - dup].vst;
            SetStart(tk[i], pos);
            Continue;
          end;
        end;
        if kind = 5 then begin
          { a WebP VP8 frame }
          flen := Bounded(V(Length(fdata)), maxOut);
          if vm = nil then vm := TVp8Model.Create(pixelBits);
          CodeVp8Stream(cd, vm, fdata, flen);
          Continue;
        end;
        if kind = 4 then begin
          { a WebP VP8L stream }
          wst.sub := Bounded(V(wst.sub), 1);
          if wst.sub = WK_ALPH then begin
            wst.width := Bounded(V(wst.width), 1 shl 24);
            wst.height := Bounded(V(wst.height), 1 shl 24);
          end;
          flen := Bounded(V(Length(fdata)), maxOut);
          if wstate = nil then wstate := TWebpState.Create(pixelBits);
          CodeWebpStream(cd, wstate, wst, fdata, flen);
          Continue;
        end;
        if kind = 3 then begin
          { an IFF ANIM's BODY or DLTA }
          iff.sub := Bounded(V(iff.sub), 2);
          { a BODY starts an animation: its shape }
          if iff.sub <> IK_DLTA5 then begin
            iff.width := Bounded(V(iff.width), 65535);
            iff.height := Bounded(V(iff.height), 65535);
            iff.planes := Bounded(V(iff.planes), 8);
            if (iff.width < 1) or (iff.height < 1) or (iff.planes < 1) or
               (SizeInt(iff.width) * iff.height > SizeInt(1) shl 24) then
              raise Exception.Create('paiacodec: damaged stream');
            ist.Free;
            ist := TAnimState.Create(iff.width, iff.height, iff.planes);
          end else begin
            iff.interleave := Bounded(V(iff.interleave), 255);
            iff.xorMode := Bounded(V(Ord(iff.xorMode)), 1) <> 0;
          end;
          if ist = nil then raise Exception.Create('paiacodec: damaged stream');
          flen := Bounded(V(Length(fdata)), maxOut);
          if itm = nil then begin
            itm := TTokenModel.Create(pixelBits - 2);
            ipm := TDibModel.Create(pixelBits);
          end;
          CodeIffChunk(cd, itm, ipm, ist, iff, fdata, flen);
          Continue;
        end;
        if kind = 2 then begin
          { an ANI frame's bitmap }
          dib.width := Bounded(V(dib.width), 4096);
          dib.height := Bounded(V(dib.height), 8192);
          dib.bpp := Bounded(V(dib.bpp), 32);
          flen := Bounded(V(Length(fdata)), maxOut);
          { the previous frame of the same shape }
          prevDib := nil;
          for k := i - 1 downto 0 do
            if (tk[k].kind = 2) and (tk[k].dib.width = dib.width) and
               (tk[k].dib.height = dib.height) and (tk[k].dib.bpp = dib.bpp) then begin
              prevDib := tk[k].fdata; Break;
            end;
          if dm = nil then dm := TDibModel.Create(pixelBits);
          CodeDib(cd, dm, dib, fdata, flen, prevDib);
          Continue;
        end;
        if kind = 1 then begin
          { a FLIC chunk }
          newStream := (fimg = nil) or (cd.encoding and (fli.stream <> fliStream));
          newStream := Bounded(V(Ord(newStream)), 1) <> 0;
          if newStream then begin
            fli.width := Bounded(V(fli.width), 65535);
            fli.height := Bounded(V(fli.height), 65535);
            if (fli.width < 1) or (fli.height < 1) or
               (SizeInt(fli.width) * fli.height > MAX_PIXELS) then
              raise Exception.Create('paiacodec: damaged stream');
            fimg.Free;
            fimg := TFliImage.Create(fli.width, fli.height);
            fliStream := fli.stream;
          end;
          if fimg = nil then raise Exception.Create('paiacodec: damaged stream');
          if fm = nil then fm := TFliModel.Create(pixelBits);
          fli.ctype := Bounded(V(fli.ctype), 255);
          flen := Bounded(V(Length(fdata)), maxOut);
          CodeChunk(cd, fm, fimg, fli.ctype, fdata, flen);
          Continue;
        end;
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
        newStream := (canvas = nil) or (cd.encoding and (img.stream <> gifStream));
        gifStream := img.stream;
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
    vm.Free;
    wstate.Free;
    ist.Free; ipm.Free; itm.Free;
    dm.Free;
    fimg.Free;
    fm.Free;
    canvas.Free;
    pm.Free;
    bm.Free;
  end;
end;

function Compress(const d: TBytes; out stats: TCodecStats): TBytes;
var imgs: TGifImages; flis: TFliChunks; dibs: TDibs; iffs: TIffChunks; wsts: TWebpStreams;
    vsts: TVp8Streams; tk, all: TTakenArray; raw, body: TBytes;
    i, j, count, n: Integer; q, o: SizeInt; cd: TCoder; t: TTaken; pixels: QWord;
    byteBits, pixelBits: Integer;
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

  { the FLIC chunks and the ANI bitmaps; all kinds in file order, without
    overlaps }
  flis := FindFliChunks(d);
  stats.fliChunks := Length(flis);
  dibs := FindDibs(d);
  stats.dibs := Length(dibs);
  iffs := FindIffChunks(d);
  { a DLTA before any BODY has no frame to change: such an ANIM stays as bytes }
  if (Length(iffs) > 0) and (iffs[0].sub = IK_DLTA5) then iffs := nil;
  stats.iffChunks := Length(iffs);
  wsts := FindWebpStreams(d);
  stats.webpStreams := Length(wsts);
  vsts := FindVp8Streams(d);
  stats.vp8Frames := Length(vsts);
  all := nil; SetLength(all, count + Length(flis) + Length(dibs) + Length(iffs) + Length(wsts) + Length(vsts));
  n := count;
  for j := 0 to High(flis) do begin
    t := Default(TTaken);
    t.kind := 1; t.fli := flis[j];
    t.fdata := Copy(d, t.fli.dataStart, t.fli.dataEnd - t.fli.dataStart);
    all[n] := t; Inc(n);
  end;
  for j := 0 to High(dibs) do begin
    t := Default(TTaken);
    t.kind := 2; t.dib := dibs[j];
    t.fdata := Copy(d, t.dib.dataStart, t.dib.dataEnd - t.dib.dataStart);
    all[n] := t; Inc(n);
  end;
  for j := 0 to High(iffs) do begin
    t := Default(TTaken);
    t.kind := 3; t.iff := iffs[j];
    t.fdata := Copy(d, t.iff.dataStart, t.iff.dataEnd - t.iff.dataStart);
    all[n] := t; Inc(n);
  end;
  for j := 0 to High(wsts) do begin
    t := Default(TTaken);
    t.kind := 4; t.wst := wsts[j];
    t.fdata := Copy(d, t.wst.dataStart, t.wst.dataEnd - t.wst.dataStart);
    all[n] := t; Inc(n);
  end;
  for j := 0 to High(vsts) do begin
    t := Default(TTaken);
    t.kind := 5; t.vst := vsts[j];
    t.fdata := Copy(d, t.vst.dataStart, t.vst.dataEnd - t.vst.dataStart);
    all[n] := t; Inc(n);
  end;
  for j := 0 to count - 1 do all[j] := tk[j];
  { by start (an insertion sort: the lists are each sorted already) }
  for i := 1 to n - 1 do begin
    t := all[i]; j := i - 1;
    while (j >= 0) and (StartOf(all[j]) > StartOf(t)) do begin all[j + 1] := all[j]; Dec(j); end;
    all[j + 1] := t;
  end;
  count := 0; q := 0;
  for i := 0 to n - 1 do begin
    if StartOf(all[i]) < q then Continue;
    all[count] := all[i]; Inc(count);
    q := EndOf(all[i]);
  end;
  SetLength(all, count);
  tk := all;

  { the bytes without the images' data; each image's place in them }
  raw := nil; SetLength(raw, Length(d));
  q := 0; o := 0;
  for i := 0 to count - 1 do begin
    Move(d[q], raw[o], StartOf(tk[i]) - q);
    o := o + StartOf(tk[i]) - q;
    q := EndOf(tk[i]);
    SetStart(tk[i], o);
  end;
  if Length(d) > q then Move(d[q], raw[o], Length(d) - q);
  o := o + Length(d) - q;
  SetLength(raw, o);

  pixels := 0;
  for i := 0 to count - 1 do pixels := pixels + QWord(tk[i].n) + QWord(Length(tk[i].fdata));
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
    if tk[i].kind = 0 then data := Rebuild(tk[i].px, tk[i].n, tk[i].info)
    else data := tk[i].fdata;
    total := Length(Result) + Length(data);
    if total > maxOut then raise Exception.Create('paiacodec: output larger than declared');
    SetLength(Result, total);
    Move(raw[q], Result[o], StartOf(tk[i]) - q);
    o := o + StartOf(tk[i]) - q;
    q := StartOf(tk[i]);
    if Length(data) > 0 then Move(data[0], Result[o], Length(data));
    o := o + Length(data);
  end;
  if Length(raw) > q then Move(raw[q], Result[o], Length(raw) - q);
  o := o + Length(raw) - q;
  SetLength(Result, o);
end;

end.
