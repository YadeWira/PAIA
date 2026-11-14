{ flif_replay FILE [TRACE]: replays a FLIF's decisions with paiaflif, writes
  them (as the reference decoder's RAC_TRACE does: bit 31 the bit, the low
  16 bits the 12-bit chance, or 0x10000 for a uniform bit) and encodes
  them again with TFlifRacOut: the bytes that come out must be the file's. }
program flif_replay;
{$mode objfpc}{$H+}
uses SysUtils, Classes, paiaflif;

type
  TTraceBits = class(TFlifBits)
    rin: TFlifRacIn;
    rout: TFlifRacOut;
    tr: TFileStream;
    function Decide(b12: Integer): Boolean; override;
    function Uniform: Boolean; override;
    procedure Emit(w: LongWord);
  end;

procedure TTraceBits.Emit(w: LongWord);
begin
  Inc(count);
  if tr <> nil then tr.WriteBuffer(w, 4);
end;

function TTraceBits.Decide(b12: Integer): Boolean;
begin
  Result := rin.Get12(b12);
  rout.Put12(Result, b12);
  Emit(LongWord(b12) or (LongWord(Ord(Result)) shl 31));
end;

function TTraceBits.Uniform: Boolean;
begin
  Result := rin.GetHalf;
  rout.PutHalf(Result);
  Emit($10000 or (LongWord(Ord(Result)) shl 31));
end;

var d: TBytes; fs: TFileStream; h: TFlifHeader; b: TTraceBits; i, same: SizeInt; t0: QWord;
begin
  fs := TFileStream.Create(ParamStr(1), fmOpenRead);
  SetLength(d, fs.Size); fs.ReadBuffer(d[0], fs.Size); fs.Free;
  if not ParseFlifHeader(d, h) then begin WriteLn('not a FLIF this replay takes'); Halt(1); end;
  WriteLn('FLIF ', h.width, 'x', h.height, ' planes ', h.numPlanes, ' frames ', h.numFrames,
          ' interlaced ', h.interlaced, ' stream at ', h.racStart);
  b := TTraceBits.Create;
  b.rin := TFlifRacIn.Create(d, h.racStart, Length(d));
  b.rout := TFlifRacOut.Create;
  if ParamCount > 1 then b.tr := TFileStream.Create(ParamStr(2), fmCreate) else b.tr := nil;
  t0 := GetTickCount64;
  try
    ReplayFlif(h, b);
  except
    on e: Exception do WriteLn('stopped: ', e.Message, ' after ', b.count, ' decisions');
  end;
  WriteLn('decisions ', b.count, ', bytes read ', b.rin.Consumed - h.racStart, ' of ', Length(d) - h.racStart,
          ', ', (GetTickCount64 - t0), ' ms');
  same := 0;
  for i := 0 to b.rout.outLen - 1 do
    if (h.racStart + i < Length(d)) and (b.rout.outBuf[i] = d[h.racStart + i]) then Inc(same) else Break;
  WriteLn('encoded again: ', b.rout.outLen, ' final bytes, the first ', same, ' equal to the file''s; tail ',
          Length(d) - h.racStart - b.rout.outLen, ' bytes');
  b.tr.Free;
end.
