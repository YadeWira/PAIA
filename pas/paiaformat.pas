{ The .paia file: ONE compressed file, with its declared size, hash and
  extension. Version 1, written since 0.1.0, read forever
  (doc/STABILITY.md):

    magic      4 B    "PAIA"
    version    1 B    1
    flags      1 B    bit 0: stored (the payload is the original itself)
    reserved   2 B    0
    orig_size  u64 LE
    hash       16 B   BLAKE3-128 of the original
    ext_len    1 B    0 to 15
    ext        ext_len bytes: letters, digits, '_' and '-'
    payload    the rest: the codec stream (paiacodec), or the original

  The writer and the reader validate with the same rules: what is written
  can be read, and what is refused on reading cannot be written. }
unit paiaformat;

{$I paia.inc}
{$ifopt R-}{$fatal paiaformat: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal paiaformat: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, paiablake3;

const
  MAGIC: array[0..3] of Byte = (Ord('P'), Ord('A'), Ord('I'), Ord('A'));
  VERSION = 1;
  FLAG_STORED = 1;
  KNOWN_FLAGS = FLAG_STORED;
  { magic, version, flags, reserved, orig_size, hash, ext_len }
  HEADER_SIZE = 8 + 8 + 16 + 1;
  MAX_EXT = 15;
  { the largest a stream may claim to expand: a bomb is refused before it
    is decoded }
  MAX_RATIO = 65536;

type
  TPaiaError = (
    peNone,
    peShortFile, peNotPaia, peFutureVersion, peUnknownFlag, peReservedNotZero,
    peBadExtension, peBadOrigSize, peRatioExceeded);

  TPaiaResult = record
    err: TPaiaError;
    value: QWord;               { the version, with peFutureVersion }
    function Ok: Boolean;
    function Text: string;
  end;

  TPaia = record
    orig_size: QWord;
    hash: THash16;
    stored: Boolean;
    ext: string;
    payload: TBytes;
  end;

function IsPaia(const d: TBytes): Boolean;
function Open(const data: TBytes; out p: TPaia): TPaiaResult;
function ValidExtension(const ext: string): Boolean;
function WritePaia(const payload: TBytes; const hash: THash16; origSize: QWord;
                   out bytes: TBytes; stored: Boolean; const ext: string): TPaiaResult;

implementation

const
  ERROR_NAMES: array[TPaiaError] of string = (
    'None', 'ShortFile', 'NotPaia', 'FutureVersion', 'UnknownFlag', 'ReservedNotZero',
    'BadExtension', 'BadOrigSize', 'RatioExceeded');

function TPaiaResult.Ok: Boolean;
begin Result := err = peNone; end;

function TPaiaResult.Text: string;
begin
  if err = peFutureVersion then Result := ERROR_NAMES[err] + '(' + IntToStr(value) + ')'
  else Result := ERROR_NAMES[err];
end;

function PaiaFail(e: TPaiaError; v: QWord = 0): TPaiaResult;
begin
  Result := Default(TPaiaResult);
  Result.err := e; Result.value := v;
end;

function IsPaia(const d: TBytes): Boolean;
var i: Integer;
begin
  Result := Length(d) >= 4;
  if Result then
    for i := 0 to 3 do if d[i] <> MAGIC[i] then Exit(False);
end;

function ValidExtension(const ext: string): Boolean;
var c: Char;
begin
  if Length(ext) > MAX_EXT then Exit(False);
  for c in ext do
    if not (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then Exit(False);
  Result := True;
end;

{ the descriptor's rules, the same for the reader and the writer }
function Validate(origSize, payloadSize: QWord; stored: Boolean): TPaiaResult;
begin
  Result := PaiaFail(peNone);
  if stored then begin
    if origSize <> payloadSize then Result := PaiaFail(peBadOrigSize);
  end else begin
    if origSize > QWord(High(SizeInt) div 2) then Result := PaiaFail(peBadOrigSize)
    else if origSize > payloadSize * MAX_RATIO then Result := PaiaFail(peRatioExceeded);
  end;
end;

function Open(const data: TBytes; out p: TPaia): TPaiaResult;
var i, el, o: SizeInt;
begin
  p := Default(TPaia);
  if Length(data) < 4 then Exit(PaiaFail(peShortFile));
  if not IsPaia(data) then Exit(PaiaFail(peNotPaia));
  if Length(data) < HEADER_SIZE then Exit(PaiaFail(peShortFile));
  if data[4] <> VERSION then Exit(PaiaFail(peFutureVersion, data[4]));
  if (data[5] and not KNOWN_FLAGS) <> 0 then Exit(PaiaFail(peUnknownFlag));
  if (data[6] <> 0) or (data[7] <> 0) then Exit(PaiaFail(peReservedNotZero));
  p.stored := (data[5] and FLAG_STORED) <> 0;
  p.orig_size := 0;
  for i := 7 downto 0 do p.orig_size := (p.orig_size shl 8) or data[8 + i];
  Move(data[16], p.hash[0], 16);
  el := data[32];
  if (el > MAX_EXT) or (HEADER_SIZE + el > Length(data)) then Exit(PaiaFail(peBadExtension));
  p.ext := '';
  for i := 0 to el - 1 do p.ext := p.ext + Chr(data[33 + i]);
  if not ValidExtension(p.ext) then Exit(PaiaFail(peBadExtension));
  o := HEADER_SIZE + el;
  Result := Validate(p.orig_size, Length(data) - o, p.stored);
  if not Result.Ok then Exit;
  p.payload := Copy(data, o, Length(data) - o);
end;

function WritePaia(const payload: TBytes; const hash: THash16; origSize: QWord;
                   out bytes: TBytes; stored: Boolean; const ext: string): TPaiaResult;
var e: string; o, i: SizeInt;
begin
  bytes := nil;
  e := ext;
  if not ValidExtension(e) then e := '';
  Result := Validate(origSize, Length(payload), stored);
  if not Result.Ok then Exit;
  SetLength(bytes, HEADER_SIZE + Length(e) + Length(payload));
  Move(MAGIC[0], bytes[0], 4);
  bytes[4] := VERSION;
  bytes[5] := Ord(stored) * FLAG_STORED;
  bytes[6] := 0; bytes[7] := 0;
  for i := 0 to 7 do bytes[8 + i] := Byte(origSize shr (8 * i));
  Move(hash[0], bytes[16], 16);
  bytes[32] := Length(e);
  o := 33;
  for i := 1 to Length(e) do begin bytes[o] := Ord(e[i]); Inc(o); end;
  if Length(payload) > 0 then Move(payload[0], bytes[o], Length(payload));
end;

end.
