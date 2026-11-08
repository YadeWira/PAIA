{ A whole file to a .paia and back: the codec (paiacodec) inside the file
  format (paiaformat).

  Pack: compress, verify (decompress and compare; unless told not to), hash
  the original, write. A stream no smaller than the original is not worth
  it, and the original is stored instead; so is one that did not come
  back, which is a bug in the codec (codecFailed says so).
  Unpack: open the format, refuse a declared size above the caller's cap,
  decode with that size as the decoder's cap, check the length and the hash.
  What comes out of Unpack with ukOk is the original, byte for byte. }
unit paiapack;

{$I paia.inc}
{$ifopt R-}{$fatal paiapack: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal paiapack: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, paiablake3, paiaformat, paiacodec;

type
  TPackError = (
    ukOk,
    { the .paia is malformed (detail in fmt) }
    ukFormat,
    { the stream does not decode (detail in codecError) }
    ukCodec,
    { the declared size is above the caller's cap }
    ukTooLarge,
    { decoded, but not to the declared length or hash: damaged }
    ukSizeMismatch, ukHashMismatch);

  TPackResult = record
    err: TPackError;
    fmt: TPaiaResult;
    codecError: string;
    { Pack: what the codec found and took; whether the original went as it
      is (not smaller, or codecFailed) }
    stats: TCodecStats;
    stored: Boolean;
    { Pack: the codec raised, or its stream did not come back: a bug,
      stored as is so that nothing is lost }
    codecFailed: Boolean;
    { Unpack: the original's extension the .paia keeps, without the dot }
    ext: string;
    function Ok: Boolean;
    function Text: string;
  end;

function Pack(const original: TBytes; out paia: TBytes; verify: Boolean = True;
              const ext: string = ''): TPackResult;

{ With ukHashMismatch, `original` holds what was decoded and `expected` the
  hash it should have had (for --keep-corrupt); with any other error it is
  empty. }
function Unpack(const paia: TBytes; maxOutput: QWord; out original: TBytes;
                out expected: THash16): TPackResult;

implementation

uses paiastage;

const
  ERROR_NAMES: array[TPackError] of string = ('Ok', 'Format', 'Codec', 'TooLarge', 'SizeMismatch', 'HashMismatch');

function TPackResult.Ok: Boolean;
begin Result := err = ukOk; end;

function TPackResult.Text: string;
begin
  Result := ERROR_NAMES[err];
  case err of
    ukFormat: Result := Result + '(' + fmt.Text + ')';
    ukCodec: Result := Result + '(' + codecError + ')';
  end;
end;

function PackFail(e: TPackError): TPackResult;
begin
  Result := Default(TPackResult);
  Result.err := e;
end;

function Pack(const original: TBytes; out paia: TBytes; verify: Boolean; const ext: string): TPackResult;
var stream, back: TBytes; h: THash16; ok: Boolean;
begin
  paia := nil;
  Result := PackFail(ukOk);
  stream := nil;
  ok := False;
  try
    StageEnter(stEncode);
    stream := Compress(original, Result.stats);
    ok := True;
    if verify then begin
      StageEnter(stVerify);
      back := Decompress(stream, Length(original));
      ok := (Length(back) = Length(original)) and
            ((Length(original) = 0) or CompareMem(@back[0], @original[0], Length(original)));
      if not ok then Result.codecError := 'its stream does not decode to the input';
    end;
  except
    on e: EOutOfMemory do raise;
    on e: Exception do begin
      ok := False;
      Result.codecError := e.ClassName + ': ' + e.Message;
    end;
  end;
  Result.codecFailed := not ok;
  StageEnter(stHash);
  h := Blake3_128(original);
  Result.stored := not ok or (Length(stream) >= Length(original));
  if not Result.stored then begin
    Result.fmt := WritePaia(stream, h, Length(original), paia, False, ext);
    { a stream that claims too much for its size: stored instead }
    if not Result.fmt.Ok then Result.stored := True;
  end;
  if Result.stored then Result.fmt := WritePaia(original, h, Length(original), paia, True, ext);
  if not Result.fmt.Ok then begin paia := nil; Result.err := ukFormat; end;
end;

function Unpack(const paia: TBytes; maxOutput: QWord; out original: TBytes;
                out expected: THash16): TPackResult;
var p: TPaia; actual: THash16;
begin
  original := nil;
  FillChar(expected, SizeOf(expected), 0);
  Result := PackFail(ukOk);
  Result.fmt := Open(paia, p);
  if not Result.fmt.Ok then begin Result.err := ukFormat; Exit; end;
  expected := p.hash;
  Result.ext := p.ext;
  Result.stored := p.stored;
  if p.orig_size > maxOutput then Exit(PackFail(ukTooLarge));
  StageEnter(stDecode);
  if p.stored then original := p.payload
  else
    try
      original := Decompress(p.payload, SizeInt(p.orig_size));
    except
      on e: EOutOfMemory do raise;
      on e: Exception do begin
        original := nil;
        Result.err := ukCodec;
        Result.codecError := e.Message;
        Exit;
      end;
    end;
  if QWord(Length(original)) <> p.orig_size then begin original := nil; Exit(PackFail(ukSizeMismatch)); end;
  StageEnter(stHash);
  actual := Blake3_128(original);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then Result.err := ukHashMismatch;
end;

end.
