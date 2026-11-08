{ paia selftest (doc/CLI.md): the samples inside the binary
  (paiaselftest.inc, written by tests/tools/gen_selftest.py: a GIF
  animation, a FLIC with every chunk kind, an ANI with repeated frames, an
  IFF ANIM in XOR mode, a lossy WebP with lossless alpha) compressed and
  extracted on every path of the model this build has (paiasysinfo: the
  Pascal one, and the C one where it is linked in). Each .paia has to be
  the very bytes the include holds, on every path, and each has to come
  back as its sample. From PJA's pjaselftest (same family, author,
  licence). }
unit paiaselftest;

{$I paia.inc}
{$ifopt R-}{$fatal paiaselftest: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal paiaselftest: overflow checks ($Q+) are mandatory}{$endif}

interface

uses paiasysinfo;

{ Prints a line per path and a summary (only failures and the summary with
  quiet). 0 when every check passed, 1 if not. onePath: only `only` (--cpu),
  which the caller has checked this build has. }
function RunSelftest(quiet: Boolean; onePath: Boolean = False; only: TCpuPath = cpPascal): Integer;

implementation

uses SysUtils, paiablake3, paiapack, paiainfo;

{$I paiaselftest.inc}

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function RunSelftest(quiet: Boolean; onePath: Boolean; only: TCpuPath): Integer;
var was, p: TCpuPath; k, checks, failed, pathFailed, paths: Integer; data, want, got, back: TBytes;
    r: TPackResult; h: THash16; why, names: string;
begin
  was := CurrentCpuPath;
  checks := 0; failed := 0; paths := 0; names := '';
  if not quiet then begin
    if onePath then
      Writeln('paia selftest: ', SELFTEST_COUNT, ' samples inside the binary, on the path ',
              CPU_PATH_NAMES[only], ' (--cpu)')
    else
      Writeln('paia selftest: ', SELFTEST_COUNT, ' samples inside the binary, on every path here (',
              SupportedPaths, ')');
    for k := 0 to SELFTEST_COUNT - 1 do begin
      SelftestSample(k, data, want);
      Writeln('  ', SELFTEST_NAMES[k], ': ', Length(data), ' B -> ', Length(want), ' B, .paia blake3-128 ',
              HexBytes(Blake3_128(want)));
    end;
  end;
  try
    for p := Low(TCpuPath) to High(TCpuPath) do begin
      if not CpuPathSupported(p) or (onePath and (p <> only)) then Continue;
      Inc(paths);
      if names <> '' then names := names + ' ';
      names := names + CPU_PATH_NAMES[p];
      SetCpuPath(p);
      pathFailed := 0;
      for k := 0 to SELFTEST_COUNT - 1 do begin
        SelftestSample(k, data, want);
        Inc(checks);
        why := '';
        r := Pack(data, got, True, SELFTEST_EXTS[k]);
        if not r.Ok then why := 'compress failed: ' + r.Text
        else if r.codecFailed then why := 'the codec failed: ' + r.codecError
        else if not SameBytes(got, want) then
          why := 'a different .paia: ' + IntToStr(Length(got)) + ' B, blake3-128 ' + HexBytes(Blake3_128(got))
        else begin
          r := Unpack(got, QWord(Length(data)), back, h);
          if not r.Ok then why := 'extract failed: ' + r.Text
          else if not SameBytes(back, data) then why := 'extracted to other bytes';
        end;
        if why <> '' then begin
          Inc(failed); Inc(pathFailed);
          Writeln(StdErr, 'paia: selftest: ', SELFTEST_NAMES[k], ' on ', CPU_PATH_NAMES[p], ': ', why);
        end;
      end;
      if not quiet then begin
        if pathFailed = 0 then Writeln('  path ', CPU_PATH_NAMES[p], ': ok')
        else Writeln('  path ', CPU_PATH_NAMES[p], ': ', pathFailed, ' FAILED');
      end;
    end;
  finally
    SetCpuPath(was);
  end;
  if failed = 0 then begin
    Writeln('selftest: ', checks, ' of ', checks, ' checks passed on ', paths, ' path(s) (', names,
            '): every .paia the expected bytes, every sample back');
    Result := 0;
  end else begin
    Writeln(StdErr, 'paia: selftest: ', failed, ' of ', checks, ' checks FAILED. This is a bug in PAIA: please run',
            ' paia report and open an issue at ', ISSUES_URL);
    Result := 1;
  end;
end;

end.
