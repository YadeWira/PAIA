{ The structure of the files PAIA knows, for info, report and --json: the
  .paia file, and the animated formats it takes (GIF, FLI/FLC, ANI, IFF
  ANIM, WebP), as the codec's own finders see them: what is listed is what
  PAIA finds. Sizes, places and shapes only: never pixels, nor what a
  file's metadata says. }
unit paiainfoimg;

{$I paia.inc}
{$ifopt R-}{$fatal paiainfoimg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal paiainfoimg: overflow checks ($Q+) are mandatory}{$endif}

interface

implementation

uses SysUtils, paiainfo, paiaformat, paiacodec, paiagif, paiafli, paiadib, paiaiff, paiawebp, paiavp8;

const
  { past this many, items are counted, not listed }
  MAX_LISTED = 64;

{ ---------- .paia ---------- }

function ProbePaia(const d: TBytes): Boolean;
begin
  Result := IsPaia(d);
end;

procedure DescribePaia(const d: TBytes; n: TInfoNode);
var p: TPaia; r: TPaiaResult; c, s: TInfoNode;
begin
  n.Str('format', 'paia');
  n.Num('size', Length(d));
  r := Open(d, p);
  c := n.Obj('container');
  if Length(d) > 4 then c.Num('version', d[4]);
  if not r.Ok then begin
    c.Str('problem', r.Text);
    Exit;
  end;
  c.Num('original_size', p.orig_size);
  c.Str('blake3_128', HexBytes(p.hash));
  c.Str('extension', p.ext);
  c.Bool('stored', p.stored);
  s := n.Obj('stream');
  if p.stored then begin
    s.Str('kind', 'none: the original stored as is');
    Exit;
  end;
  if Length(p.payload) > 0 then s.Num('version', p.payload[0]);
  if Length(p.payload) >= 3 then begin
    s.Num('byte_table_bits', p.payload[1]);
    s.Num('pixel_table_bits', p.payload[2]);
  end;
  s.Num('bytes', Length(p.payload));
  if (Length(p.payload) > 0) and (p.payload[0] <> STREAM_VERSION) then
    s.Str('problem', 'a stream version this release does not know');
end;

{ ---------- GIF ---------- }

function GifAt(const d: TBytes): Boolean;
var p, last: SizeInt;
begin
  Result := False;
  last := Length(d) - 13;
  if last > 4096 then last := 4096;
  for p := 0 to last do
    if (d[p] = Ord('G')) and (d[p + 1] = Ord('I')) and (d[p + 2] = Ord('F')) and (d[p + 3] = Ord('8'))
       and ((d[p + 4] = Ord('7')) or (d[p + 4] = Ord('9'))) and (d[p + 5] = Ord('a')) then Exit(True);
end;

function ProbeGif(const d: TBytes): Boolean;
begin
  Result := GifAt(d);
end;

procedure DescribeGif(const d: TBytes; n: TInfoNode);
var imgs: TGifImages; l, o: TInfoNode; i, streams, inter, transp: Integer;
begin
  n.Str('format', 'GIF');
  n.Num('size', Length(d));
  imgs := FindGifImages(d);
  streams := 0; inter := 0; transp := 0;
  for i := 0 to High(imgs) do begin
    if imgs[i].stream + 1 > streams then streams := imgs[i].stream + 1;
    if imgs[i].interlaced then Inc(inter);
    if imgs[i].transparent >= 0 then Inc(transp);
  end;
  n.Num('gif_streams', streams);
  if Length(imgs) > 0 then n.Str('canvas', IntToStr(imgs[0].canvasW) + 'x' + IntToStr(imgs[0].canvasH));
  n.Num('images', Length(imgs));
  n.Num('interlaced', inter);
  n.Num('with_transparency', transp);
  l := n.List('image_list');
  for i := 0 to High(imgs) do begin
    if i = MAX_LISTED then begin n.Num('images_not_listed', Length(imgs) - MAX_LISTED); Break; end;
    o := l.Obj;
    o.Num('offset', imgs[i].mcsPos);
    o.Str('size', IntToStr(imgs[i].width) + 'x' + IntToStr(imgs[i].height));
    o.Str('at', IntToStr(imgs[i].left) + ',' + IntToStr(imgs[i].top));
    o.Num('lzw_bytes', imgs[i].dataEnd - imgs[i].dataStart);
    o.Num('min_code_size', imgs[i].mcs);
    o.Num('disposal', imgs[i].disposal);
    o.line := IntToStr(imgs[i].width) + 'x' + IntToStr(imgs[i].height) + ' at ' + IntToStr(imgs[i].left) + ',' +
              IntToStr(imgs[i].top) + ', ' + IntToStr(imgs[i].dataEnd - imgs[i].dataStart) + ' B of LZW, disposal ' +
              IntToStr(imgs[i].disposal);
    if imgs[i].interlaced then o.line := o.line + ', interlaced';
    if imgs[i].transparent >= 0 then o.line := o.line + ', transparent ' + IntToStr(imgs[i].transparent);
  end;
end;

{ ---------- FLI / FLC ---------- }

function ProbeFlic(const d: TBytes): Boolean;
var m: Integer;
begin
  Result := False;
  if Length(d) < 128 then Exit;
  m := d[4] or (d[5] shl 8);
  Result := (m = $AF11) or (m = $AF12);
end;

procedure DescribeFlic(const d: TBytes; n: TInfoNode);
var c: TFliChunks; i, m: Integer; counts: array[0..31] of Integer; bytes: Int64; k: TInfoNode;
const NAMES: array[0..31] of string = ('', '', '', '', '', '', '', 'DELTA_FLC', '', '', '', '', 'DELTA_FLI',
  'BLACK', '', 'BYTE_RUN', 'COPY', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '');
begin
  m := d[4] or (d[5] shl 8);
  if m = $AF11 then n.Str('format', 'FLI') else n.Str('format', 'FLC');
  n.Num('size', Length(d));
  n.Str('frame_size', IntToStr(d[8] or (d[9] shl 8)) + 'x' + IntToStr(d[10] or (d[11] shl 8)));
  n.Num('depth', d[12] or (d[13] shl 8));
  n.Num('frames', d[6] or (d[7] shl 8));
  c := FindFliChunks(d);
  FillChar(counts, SizeOf(counts), 0);
  bytes := 0;
  for i := 0 to High(c) do begin
    if (c[i].ctype >= 0) and (c[i].ctype <= 31) then Inc(counts[c[i].ctype]);
    bytes := bytes + c[i].dataEnd - c[i].dataStart;
  end;
  n.Num('pixel_chunks', Length(c));
  n.Num('pixel_chunk_bytes', bytes);
  k := n.Obj('chunks_by_type');
  for i := 0 to 31 do
    if (counts[i] > 0) and (NAMES[i] <> '') then k.Num(NAMES[i], counts[i]);
end;

{ ---------- ANI ---------- }

function ProbeAni(const d: TBytes): Boolean;
begin
  Result := (Length(d) >= 12) and (d[0] = Ord('R')) and (d[1] = Ord('I')) and (d[2] = Ord('F')) and
    (d[3] = Ord('F')) and (d[8] = Ord('A')) and (d[9] = Ord('C')) and (d[10] = Ord('O')) and (d[11] = Ord('N'));
end;

procedure DescribeAni(const d: TBytes; n: TInfoNode);
var b: TDibs; l: TInfoNode; i: Integer;
begin
  n.Str('format', 'ANI');
  n.Num('size', Length(d));
  b := FindDibs(d);
  n.Num('bitmaps', Length(b));
  l := n.List('bitmap_list');
  for i := 0 to High(b) do begin
    if i = MAX_LISTED then begin n.Num('bitmaps_not_listed', Length(b) - MAX_LISTED); Break; end;
    l.Str('', IntToStr(b[i].width) + 'x' + IntToStr(b[i].height) + ', ' + IntToStr(b[i].bpp) + ' bits, ' +
          IntToStr(b[i].dataEnd - b[i].dataStart) + ' B');
  end;
end;

{ ---------- IFF ANIM ---------- }

function ProbeAnim(const d: TBytes): Boolean;
begin
  Result := (Length(d) >= 12) and (d[0] = Ord('F')) and (d[1] = Ord('O')) and (d[2] = Ord('R')) and
    (d[3] = Ord('M')) and (d[8] = Ord('A')) and (d[9] = Ord('N')) and (d[10] = Ord('I')) and (d[11] = Ord('M'));
end;

procedure DescribeAnim(const d: TBytes; n: TInfoNode);
var c: TIffChunks; i, bodies, deltas: Integer;
begin
  n.Str('format', 'IFF ANIM');
  n.Num('size', Length(d));
  c := FindIffChunks(d);
  bodies := 0; deltas := 0;
  for i := 0 to High(c) do
    if c[i].sub = IK_DLTA5 then Inc(deltas) else Inc(bodies);
  if Length(c) > 0 then begin
    n.Str('frame_size', IntToStr(c[0].width) + 'x' + IntToStr(c[0].height));
    n.Num('planes', c[0].planes);
  end;
  n.Num('bodies_taken', bodies);
  n.Num('byte_vertical_deltas_taken', deltas);
end;

{ ---------- WebP ---------- }

function ProbeWebp(const d: TBytes): Boolean;
begin
  Result := (Length(d) >= 12) and (d[0] = Ord('R')) and (d[1] = Ord('I')) and (d[2] = Ord('F')) and
    (d[3] = Ord('F')) and (d[8] = Ord('W')) and (d[9] = Ord('E')) and (d[10] = Ord('B')) and (d[11] = Ord('P'));
end;

procedure DescribeWebp(const d: TBytes; n: TInfoNode);
var w: TWebpStreams; v: TVp8Streams; i, lossless, alpha: Integer; frames, wb: Int64;
begin
  n.Str('format', 'WebP');
  n.Num('size', Length(d));
  w := FindWebpStreams(d);
  v := FindVp8Streams(d);
  lossless := 0; alpha := 0; wb := 0;
  for i := 0 to High(w) do begin
    if w[i].sub = WK_ALPH then Inc(alpha) else Inc(lossless);
    wb := wb + w[i].dataEnd - w[i].dataStart;
  end;
  frames := 0;
  for i := 0 to High(v) do frames := frames + v[i].dataEnd - v[i].dataStart;
  if (Length(w) > 0) and w[0].inFrame then n.Str('canvas', IntToStr(w[0].cw) + 'x' + IntToStr(w[0].ch));
  n.Num('vp8l_streams', lossless);
  n.Num('lossless_alpha_streams', alpha);
  n.Num('vp8l_bytes', wb);
  n.Num('vp8_frames', Length(v));
  n.Num('vp8_bytes', frames);
end;

initialization
  RegisterInfoProvider('paia', @ProbePaia, @DescribePaia);
  RegisterInfoProvider('gif', @ProbeGif, @DescribeGif);
  RegisterInfoProvider('flic', @ProbeFlic, @DescribeFlic);
  RegisterInfoProvider('ani', @ProbeAni, @DescribeAni);
  RegisterInfoProvider('anim', @ProbeAnim, @DescribeAnim);
  RegisterInfoProvider('webp', @ProbeWebp, @DescribeWebp);
end.
