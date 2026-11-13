{ paia_zpaqstd: PAIA as a zpaq-std plugin for -sat / -sae (codecs for
  specific formats), on zpaq-std's plugin ABI 1 (compressors/plug/zs_codec.h
  in YadeWira/zpaq-std).

    pas/plugin/build.sh <out dir>     -> <out dir>/paia.so (paia.dll on Windows)

  Exported C functions:
  - zpaqstd_codecs_v1(i): one codec a format, so that each can later carry
    a ZPAQL decoder of its format alone: paiagif1 (0), paiaflc1 (1),
    paiaani1 (2), paiaanim1 (3), paiawebp1 (4). zpaqstd_codec_v1 is
    paiagif1. The names are versioned (the family's rule): a new stream, or
    another ZPAQL decoder, is a new name (paiagif2...), never a change to
    one; and no name ends in z, o or 8, which zpaq-std reads as other
    families'.
    compress() gets a file's block (the file, and zpaq-std's list of
    fragments after it) and gives back PAIA's codec stream
    (paiacodec.Compress), which keeps every byte, whatever follows the
    format's end; it does not verify the stream itself, since zpaq-std
    decodes every block and compares before writing it. decompress() is
    paiacodec.Decompress with zpaq-std's exact original size as the cap.
  - zpaqstd_detect_v1: from the file's bytes only, 1 if the codec named
    takes it: the format's header at its start (a GIF's within the first
    4 KB: after a MacBinary header, say), and something of it that PAIA
    takes (GIF images, FLIC pixel chunks, ANI bitmaps, IFF ANIM frames,
    WebP VP8 or VP8L streams); 2 if it has the header but is not taken
    (for zpaq-std's +rcmd); else 0. Never reads outside the file; any
    error is a 0.
  - No global state but read-only tables: several threads may call at once.

  No ZPAQL decoder yet (data(ZS_DATA_ZPAQL) is nil): enough for -sat, which
  checks the plugin; -sae, which writes archives any zpaq can read, needs
  one, and so does a format frozen (PAIA's freeze at 1.0.0).

  CONTRACT with zpaq-std: the library field names the stream version
  ("paia stream v8"); a later stream needs a new library field (or a new
  codec name), never a silent change. }
library paia_zpaqstd;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}{$ifdef windows}paiaheap,{$endif}
  SysUtils, paiacodec, paiagif, paiafli, paiadib, paiaiff, paiawebp, paiavp8;

const
  ZS_CODEC_ABI = 1;
  ZS_ERR_DATA = -1;
  ZS_ERR_MEMORY = -2;
  ZS_DATA_INFO = 3;
  { zpaq-std hands the codecs files up to 64 MB; above this, refuse }
  MAX_BLOCK = SizeUInt(1) shl 30;
  LEVEL = 1;
  PAIA_VERSION = '0.2.0';
  STREAM = 'paia stream v8';

  F_GIF = 0; F_FLC = 1; F_ANI = 2; F_ANIM = 3; F_WEBP = 4;

type
  {$packrecords c}
  TBoundFn      = function(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
  TCompressFn   = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           level: LongInt): Int64; cdecl;
  TDecompressFn = function(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
                           param: LongInt): Int64; cdecl;
  TQueryFn      = function(what: LongInt; src: Pointer; n: SizeUInt): Int64; cdecl;
  TDataFn       = function(what: LongInt; size: PSizeUInt): Pointer; cdecl;

  TZsCodec = record
    abi: LongInt;
    name: PChar;
    library_: PChar;
    min_level, max_level: LongInt;
    bound: TBoundFn;
    compress_: TCompressFn;
    decompress_: TDecompressFn;
    query: TQueryFn;
    data: TDataFn;
  end;
  PZsCodec = ^TZsCodec;
  {$packrecords default}

function Bytes(src: Pointer; n: SizeUInt): TBytes;
begin
  Result := nil;
  SetLength(Result, n);
  if n > 0 then Move(src^, Result[0], n);
end;

{ The stream is the file modelled, usually smaller; one the codec cannot
  shrink comes out a little larger, and zpaq-std then stores it as -m says. }
function CodecBound(n: SizeUInt; level: LongInt): SizeUInt; cdecl;
begin
  if n > MAX_BLOCK then Exit(0);
  Result := n + n div 4 + 65536;
end;

function CodecCompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  level: LongInt): Int64; cdecl;
var d, s: TBytes; st: TCodecStats;
begin
  if n > MAX_BLOCK then Exit(ZS_ERR_DATA);
  try
    d := Bytes(src, n);
    s := Compress(d, st);
    if SizeUInt(Length(s)) > cap then Exit(ZS_ERR_DATA);
    if Length(s) > 0 then Move(s[0], dst^, Length(s));
    Result := Length(s);
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function CodecDecompress(src: Pointer; n: SizeUInt; dst: Pointer; cap: SizeUInt;
  param: LongInt): Int64; cdecl;
var s, d: TBytes;
begin
  if (n > MAX_BLOCK) or (cap > MAX_BLOCK) then Exit(ZS_ERR_DATA);
  try
    s := Bytes(src, n);
    d := Decompress(s, cap);
    if SizeUInt(Length(d)) <> cap then Exit(ZS_ERR_DATA);
    if cap > 0 then Move(d[0], dst^, cap);
    Result := cap;
  except
    on EOutOfMemory do Result := ZS_ERR_MEMORY;
    on Exception do Result := ZS_ERR_DATA;
  end;
end;

function HasGifSignature(const d: TBytes): Boolean;
var p, last: SizeInt;
begin
  Result := False;
  last := Length(d) - 13;
  if last > 4096 then last := 4096;
  for p := 0 to last do
    if (d[p] = Ord('G')) and (d[p + 1] = Ord('I')) and (d[p + 2] = Ord('F')) and (d[p + 3] = Ord('8'))
       and ((d[p + 4] = Ord('7')) or (d[p + 4] = Ord('9'))) and (d[p + 5] = Ord('a')) then Exit(True);
end;

{ Whether the bytes start as the format does, and PAIA takes something of
  it. The Find* functions check every length against the data. }
function Takes(fmt: Integer; const d: TBytes): Boolean;
begin
  Result := False;
  case fmt of
    F_GIF:
      { a GIF's signature at the start, or after a header (MacBinary's 128
        bytes, or another one) within the first 4 KB }
      Result := HasGifSignature(d) and (Length(FindGifImages(d)) > 0);
    F_FLC:
      Result := (Length(d) >= 128) and (Length(FindFliChunks(d)) > 0);
    F_ANI:
      Result := Length(FindDibs(d)) > 0;
    F_ANIM: begin
      Result := Length(FindIffChunks(d)) > 0;
      if Result then Result := FindIffChunks(d)[0].sub <> IK_DLTA5;
    end;
    F_WEBP:
      Result := (Length(FindWebpStreams(d)) > 0) or (Length(FindVp8Streams(d)) > 0);
  end;
end;

{ Whether the bytes are of the format by their header alone: what
  zpaqstd_detect_v1 answers 2 for when PAIA does not take them (zpaq-std's
  +rcmd then gives them the method the codec's card recommends). }
function IsFormat(fmt: Integer; d: PByte; n: SizeUInt): Boolean;
  function Tag(off: SizeUInt; const t: AnsiString): Boolean;
  begin
    Result := (off + 4 <= n) and (CompareByte(d[off], t[1], 4) = 0);
  end;
var p, last: SizeInt;
begin
  Result := False;
  case fmt of
    F_GIF: begin
      last := SizeInt(n) - 6;
      if last > 4096 then last := 4096;
      for p := 0 to last do
        if (CompareByte(d[p], 'GIF8', 4) = 0) and ((d[p + 4] = Ord('7')) or (d[p + 4] = Ord('9')))
           and (d[p + 5] = Ord('a')) then Exit(True);
    end;
    F_FLC:
      { FLI, FLC and their variants: the magic after the 32-bit size }
      Result := (n >= 6) and (d[5] = $AF) and (d[4] in [$11, $12, $30, $31, $44]);
    F_ANI: Result := Tag(0, 'RIFF') and Tag(8, 'ACON');
    F_ANIM: Result := Tag(0, 'FORM') and Tag(8, 'ANIM');
    F_WEBP: Result := Tag(0, 'RIFF') and Tag(8, 'WEBP');
  end;
end;

function FormatOf(const name: AnsiString): Integer;
begin
  if name = 'paiagif1' then Result := F_GIF
  else if name = 'paiaflc1' then Result := F_FLC
  else if name = 'paiaani1' then Result := F_ANI
  else if name = 'paiaanim1' then Result := F_ANIM
  else if name = 'paiawebp1' then Result := F_WEBP
  else Result := -1;
end;

function zpaqstd_detect_v1(codecName: PChar; src: Pointer; n: SizeUInt): LongInt; cdecl;
var fmt: Integer;
begin
  { 1: PAIA takes it; 2: of the codec's format, but not taken (zpaq-std
    before 2.9.0, and without +rcmd, reads 2 as 0); 0: another format }
  Result := 0;
  if (codecName = nil) or (src = nil) or (n < 12) then Exit;
  try
    fmt := FormatOf(AnsiString(codecName));
    if fmt < 0 then Exit;
    { Takes asks for at least this header (a GIF's within its first 4 KB) }
    if not IsFormat(fmt, PByte(src), n) then Exit;
    Result := 2;
    if (n <= MAX_BLOCK) and Takes(fmt, Bytes(src, n)) then Result := 1;
  except
    Result := 0;
  end;
end;

{ the codecs' cards, for zpaq-std's codecinfoex }
function Card(const name, what, fallback: AnsiString): AnsiString;
begin
  Result := 'name=' + name + #10 +
    'version=' + PAIA_VERSION + ' (' + STREAM + ')'#10 +
    'author=Yade Bravo (YadeWira)'#10 +
    'repo=https://github.com/YadeWira/PAIA'#10 +
    'license=MIT'#10 +
    'format=' + what + ', recompressed by PAIA (its codec stream, version 8; not frozen until PAIA 1.0.0)'#10 +
    'notes=lossless; experimental; no ZPAQL decoder yet, so -sat only'#10 +
    { +rcmd: zpaq-std's method for the files of this format the codec does
      not take. Measured on them (doc/PLUGIN.md): no -ma codec is worth it
      on any of the five formats, so no fallback_ma line. }
    'fallback_m=' + fallback + #10;
end;

var
  Info: array[0..4] of AnsiString;

function DataOf(fmt: Integer; what: LongInt; size: PSizeUInt): Pointer;
begin
  if what = ZS_DATA_INFO then begin
    if size <> nil then size^ := Length(Info[fmt]);
    Result := PAnsiChar(Info[fmt]);
  end else begin
    { no ZPAQL decoder, no data prefix }
    if size <> nil then size^ := 0;
    Result := nil;
  end;
end;

function DataGif(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin Result := DataOf(F_GIF, what, size); end;
function DataFlc(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin Result := DataOf(F_FLC, what, size); end;
function DataAni(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin Result := DataOf(F_ANI, what, size); end;
function DataAnim(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin Result := DataOf(F_ANIM, what, size); end;
function DataWebp(what: LongInt; size: PSizeUInt): Pointer; cdecl;
begin Result := DataOf(F_WEBP, what, size); end;

const
  LIB = STREAM + ' (YadeWira/PAIA)';
  Codecs: array[0..4] of TZsCodec = (
    (abi: ZS_CODEC_ABI; name: 'paiagif1'; library_: LIB; min_level: LEVEL; max_level: LEVEL;
     bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress; query: nil; data: @DataGif),
    (abi: ZS_CODEC_ABI; name: 'paiaflc1'; library_: LIB; min_level: LEVEL; max_level: LEVEL;
     bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress; query: nil; data: @DataFlc),
    (abi: ZS_CODEC_ABI; name: 'paiaani1'; library_: LIB; min_level: LEVEL; max_level: LEVEL;
     bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress; query: nil; data: @DataAni),
    (abi: ZS_CODEC_ABI; name: 'paiaanim1'; library_: LIB; min_level: LEVEL; max_level: LEVEL;
     bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress; query: nil; data: @DataAnim),
    (abi: ZS_CODEC_ABI; name: 'paiawebp1'; library_: LIB; min_level: LEVEL; max_level: LEVEL;
     bound: @CodecBound; compress_: @CodecCompress; decompress_: @CodecDecompress; query: nil; data: @DataWebp));

function zpaqstd_codec_v1: PZsCodec; cdecl;
begin
  Result := @Codecs[0];
end;

function zpaqstd_codecs_v1(i: LongInt): PZsCodec; cdecl;
begin
  if (i >= 0) and (i <= High(Codecs)) then Result := @Codecs[i] else Result := nil;
end;

{ FPC 3.2.2 exports these names as written on Darwin too, where dlsym
  looks for "_zpaqstd_codecs_v1": the underscore goes in by hand there (as
  PJA's plugin does). }
{$ifdef darwin}
exports
  zpaqstd_codec_v1 name '_zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name '_zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name '_zpaqstd_detect_v1';
{$else}
exports
  zpaqstd_codec_v1 name 'zpaqstd_codec_v1',
  zpaqstd_codecs_v1 name 'zpaqstd_codecs_v1',
  zpaqstd_detect_v1 name 'zpaqstd_detect_v1';
{$endif}

begin
  IsMultiThread := True;
  Info[F_GIF] := Card('paiagif1', 'GIF', '1,5');
  Info[F_FLC] := Card('paiaflc1', 'FLI and FLC', '5,4,3');
  Info[F_ANI] := Card('paiaani1', 'ANI (animated cursors)', '5,4,3');
  Info[F_ANIM] := Card('paiaanim1', 'IFF ANIM', '5,4,3');
  Info[F_WEBP] := Card('paiawebp1', 'WebP (VP8, VP8L, lossless alpha)', '1,5');
end.
