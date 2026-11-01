{ paia: the command.

    paia a FILE...   compress each FILE into FILE's name with .paia
    paia x FILE...   extract each .paia into its name with the original's extension
    paia t FILE...   test: extract in memory and check
    options: -o DIR  write into DIR;  -f  overwrite;  -q  quiet

  THE .paia FILE (version 1; proof of concept: not frozen)
    magic      4 B    "PAIA"
    version    1 B    1
    flags      1 B    bit 0: stored (the payload is the original itself)
    reserved   2 B    0
    orig_size  u64 LE
    hash       16 B   BLAKE3-128 of the original
    ext_len    1 B    0 to 15
    ext        ext_len bytes: letters, digits, '_' and '-'
    payload    the rest: the codec stream (paiacodec), or the original

  Nothing is written unless it verified: compressing decompresses the
  stream and compares it with the input (if it does not come back, or is
  not smaller, the original is stored); extracting checks the size and the
  hash before writing. }
program paiacli;

{$I paia.inc}

uses SysUtils, Classes, paiablake3, paiacodec;

const
  MAGIC: array[0..3] of Char = ('P', 'A', 'I', 'A');
  FORMAT_VERSION = 1;
  FLAG_STORED = 1;
  HEADER = 8 + 8 + 16 + 1;

var
  outDir: string = '';
  force: Boolean = False;
  quiet: Boolean = False;

function ReadAll(const name: string): TBytes;
var f: TFileStream;
begin
  Result := nil;
  f := TFileStream.Create(name, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, f.Size);
    if Length(Result) > 0 then f.ReadBuffer(Result[0], Length(Result));
  finally
    f.Free;
  end;
end;

{ Written to a temporary name, then renamed: never a half file under the
  final name. }
procedure WriteAll(const name: string; const d: TBytes);
var f: TFileStream; tmp: string;
begin
  if FileExists(name) and not force then
    raise Exception.Create(name + ': exists (use -f to overwrite)');
  tmp := name + '.tmp' + IntToStr(GetProcessID);
  f := TFileStream.Create(tmp, fmCreate);
  try
    if Length(d) > 0 then f.WriteBuffer(d[0], Length(d));
  finally
    f.Free;
  end;
  if FileExists(name) then DeleteFile(name);
  if not RenameFile(tmp, name) then
    raise Exception.Create(name + ': cannot rename the temporary file');
end;

function ValidExt(const e: string): Boolean;
var c: Char;
begin
  if Length(e) > 15 then Exit(False);
  for c in e do
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then Exit(False);
  Result := True;
end;

function SameHash(const a, b: THash16): Boolean;
begin
  Result := CompareMem(@a[0], @b[0], 16);
end;

{ ---------------- pack / unpack ---------------- }

function Pack(const d: TBytes; const ext: string; out stats: TCodecStats;
              out stored: Boolean): TBytes;
var s, back: TBytes; h: THash16; e: string; o, i: SizeInt;
begin
  h := Blake3_128(d);
  e := ext; if not ValidExt(e) then e := '';
  stored := True;
  stats := Default(TCodecStats);
  s := nil;
  try
    s := Compress(d, stats);
    back := Decompress(s, Length(d));
    if (Length(back) = Length(d)) and ((Length(d) = 0) or CompareMem(@back[0], @d[0], Length(d)))
       and (Length(s) < Length(d)) then
      stored := False;
  except
    on E: Exception do begin
      if not quiet then Writeln(StdErr, '  codec failed (', E.Message, '): stored');
      stored := True;
    end;
  end;
  if stored then s := d;

  Result := nil;
  SetLength(Result, HEADER + Length(e) + Length(s));
  Move(MAGIC[0], Result[0], 4);
  Result[4] := FORMAT_VERSION;
  Result[5] := Ord(stored) * FLAG_STORED;
  Result[6] := 0; Result[7] := 0;
  for i := 0 to 7 do Result[8 + i] := Byte(QWord(Length(d)) shr (8 * i));
  Move(h[0], Result[16], 16);
  Result[32] := Length(e);
  o := 33;
  for i := 1 to Length(e) do begin Result[o] := Ord(e[i]); Inc(o); end;
  if Length(s) > 0 then Move(s[0], Result[o], Length(s));
end;

function Unpack(const f: TBytes; out ext: string): TBytes;
var orig: QWord; i, o, el: SizeInt; h, h2: THash16; stored: Boolean; payload: TBytes;
begin
  if (Length(f) < HEADER) or not CompareMem(@f[0], @MAGIC[0], 4) then
    raise Exception.Create('not a .paia file');
  if f[4] <> FORMAT_VERSION then raise Exception.Create('unknown .paia version ' + IntToStr(f[4]));
  if (f[5] and not FLAG_STORED) <> 0 then raise Exception.Create('unknown flags');
  if (f[6] <> 0) or (f[7] <> 0) then raise Exception.Create('reserved bytes not zero');
  stored := (f[5] and FLAG_STORED) <> 0;
  orig := 0;
  for i := 7 downto 0 do orig := (orig shl 8) or f[8 + i];
  Move(f[16], h[0], 16);
  el := f[32];
  if (el > 15) or (HEADER + el > Length(f)) then raise Exception.Create('bad extension field');
  ext := '';
  for i := 0 to el - 1 do ext := ext + Chr(f[33 + i]);
  if not ValidExt(ext) then raise Exception.Create('bad extension field');
  o := HEADER + el;
  payload := Copy(f, o, Length(f) - o);
  if stored then begin
    if QWord(Length(payload)) <> orig then raise Exception.Create('damaged: size');
    Result := payload;
  end else begin
    { the bomb check, before decoding }
    if orig > QWord(Length(payload)) * 65536 then raise Exception.Create('damaged: size');
    if orig > QWord(High(SizeInt) div 2) then raise Exception.Create('too large');
    Result := Decompress(payload, orig);
  end;
  if QWord(Length(Result)) <> orig then raise Exception.Create('damaged: size');
  h2 := Blake3_128(Result);
  if not SameHash(h, h2) then raise Exception.Create('damaged: hash');
end;

{ ---------------- the command ---------------- }

function Pct(a, b: Int64): string;
begin
  if b = 0 then Result := '-' else Result := Format('%.2f%%', [100.0 * a / b]);
end;

function Target(const src, newExt: string): string;
var base: string;
begin
  base := ChangeFileExt(ExtractFileName(src), '');
  if newExt <> '' then base := base + '.' + newExt;
  if outDir <> '' then Result := IncludeTrailingPathDelimiter(outDir) + base
  else Result := ExtractFilePath(src) + base;
end;

function DoA(const name: string): Boolean;
var d, f: TBytes; st: TCodecStats; stored: Boolean; ext, dst: string; t0: QWord;
begin
  t0 := GetTickCount64;
  d := ReadAll(name);
  ext := ExtractFileExt(name); if ext <> '' then Delete(ext, 1, 1);
  f := Pack(d, ext, st, stored);
  dst := Target(name, 'paia');
  WriteAll(dst, f);
  if not quiet then
    Writeln(name, ': ', Length(d), ' -> ', Length(f), ' (', Pct(Length(f), Length(d)), ')',
            '  images ', st.imagesTaken, '/', st.images, '  flic chunks ', st.fliChunks, '  ani bitmaps ', st.dibs, '  iff chunks ', st.iffChunks, '  vp8l ', st.webpStreams, '  vp8 ', st.vp8Frames,
            '  pixels ', st.pixels, '  exceptions ', st.exceptions,
            BoolToStr(stored, '  STORED', ''), '  ', (GetTickCount64 - t0) / 1000:0:2, ' s');
  Result := True;
end;

function DoX(const name: string; test: Boolean): Boolean;
var f, d: TBytes; ext: string;
begin
  f := ReadAll(name);
  d := Unpack(f, ext);
  if not test then WriteAll(Target(name, ext), d);
  if not quiet then Writeln(name, ': ok, ', Length(d), ' bytes');
  Result := True;
end;

var i, failures, files: Integer; cmd: string; names: TStringList;
begin
  if ParamCount < 2 then begin
    Writeln('paia 0.0.8 (proof of concept): lossless recompression of animated images');
    Writeln('usage: paia a|x|t [-o DIR] [-f] [-q] FILE...');
    Halt(2);
  end;
  cmd := ParamStr(1);
  names := TStringList.Create;
  i := 2;
  while i <= ParamCount do begin
    if ParamStr(i) = '-o' then begin Inc(i); outDir := ParamStr(i); end
    else if ParamStr(i) = '-f' then force := True
    else if ParamStr(i) = '-q' then quiet := True
    else names.Add(ParamStr(i));
    Inc(i);
  end;
  failures := 0; files := 0;
  for i := 0 to names.Count - 1 do begin
    Inc(files);
    try
      if cmd = 'a' then DoA(names[i])
      else if cmd = 'x' then DoX(names[i], False)
      else if cmd = 't' then DoX(names[i], True)
      else begin Writeln(StdErr, 'unknown command: ', cmd); Halt(2); end;
    except
      on E: Exception do begin
        Inc(failures);
        Writeln(StdErr, names[i], ': ', E.Message);
      end;
    end;
  end;
  names.Free;
  if failures > 0 then Halt(1);
end.
