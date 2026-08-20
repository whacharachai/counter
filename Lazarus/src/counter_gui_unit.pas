// SPDX-License-Identifier: AGPL-3.0-or-later
unit counter_gui_unit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ComCtrls,
  Spin, ExtCtrls, Grids, IniFiles, Process, LCLIntf, FileUtil;

type
  TMainForm = class; // forward declaration

  TWorkerThread = class(TThread)
  private
    FOwner: TMainForm;
    FExePath: string;
    FBaseArgs: TStringList;
    FFiles: TStringList;
    FMode: string;
    FStop: Boolean;
    FLogMsg: string;
    FStatusMsg: string;
    FPct: Integer;
    FRowFile, FRowIn, FRowOut, FRowPeople, FRowStatus: string;
    FCurrentFile: string;
    procedure DoLog;
    procedure DoStatus;
    procedure DoRow;
    procedure DoDone;
    procedure DrainOutput(AProcess: TProcess);
    function ParseCounters(const AFile: string; out AIn, AOut, APeople: Integer): Boolean;
    procedure RunOneFile(const AFile: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMainForm; const AExePath, AMode: string;
      ABaseArgs, AFiles: TStringList);
    destructor Destroy; override;
    procedure RequestStop;
  end;

  TMainForm = class(TForm)
    rgSource: TRadioGroup;
    edSource: TEdit;
    btnBrowse: TButton;
    gbExe: TGroupBox;
    edExePath: TEdit;
    btnExeBrowse: TButton;
    gbModel: TGroupBox;
    lblModel: TLabel;
    cbModel: TComboBox;
    btnModelBrowse: TButton;
    lblDevice: TLabel;
    cbDevice: TComboBox;
    lblTracker: TLabel;
    cbTracker: TComboBox;
    lblMaxFrames: TLabel;
    seMaxFrames: TSpinEdit;
    gbMode: TGroupBox;
    rgMode: TRadioGroup;
    gbLine: TGroupBox;
    lblLine: TLabel;
    fseLine: TFloatSpinEdit;
    rgLineAxis: TRadioGroup;
    lblInDir: TLabel;
    cbInDir: TComboBox;
    lblCount: TLabel;
    cbCount: TComboBox;
    gbAppear: TGroupBox;
    lblAppearSeconds: TLabel;
    edAppearSeconds: TEdit;
    lblMergeSeconds: TLabel;
    edMergeSeconds: TEdit;
    lblMergeGap: TLabel;
    edMergeGap: TEdit;
    gbDetect: TGroupBox;
    lblConf: TLabel;
    fseConf: TFloatSpinEdit;
    lblMinSize: TLabel;
    fseMinSize: TFloatSpinEdit;
    lblImgsz: TLabel;
    seImgsz: TSpinEdit;
    lblStride: TLabel;
    seStride: TSpinEdit;
    chkHalf: TCheckBox;
    gbOutput: TGroupBox;
    chkSave: TCheckBox;
    chkNoSnapshots: TCheckBox;
    chkShow: TCheckBox;
    chkRtspTcp: TCheckBox;
    btnRun: TButton;
    btnStop: TButton;
    btnExportCsv: TButton;
    btnAbout: TButton;
    pbProgress: TProgressBar;
    lblStatus: TLabel;
    mmLog: TMemo;
    sgResults: TStringGrid;
    lblSummary: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnBrowseClick(Sender: TObject);
    procedure btnExeBrowseClick(Sender: TObject);
    procedure btnModelBrowseClick(Sender: TObject);
    procedure btnRunClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnExportCsvClick(Sender: TObject);
    procedure btnAboutClick(Sender: TObject);
    procedure rgModeClick(Sender: TObject);
    procedure rgSourceClick(Sender: TObject);
  private
    FWorker: TWorkerThread;
    FIni: TIniFile;
    function BuildBaseArgs: TStringList;
    function ResolveTrackerPath: string;
    function BuildFileList: TStringList;
    function CounterFileFor(const AFile: string): string;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure UpdateModeUI;
    procedure SetControlsEnabled(AEnabled: Boolean);
    procedure UpdateSummary;
    procedure StartRun;
    procedure StopRun;
  public
    procedure AppendLog(const AText: string);
    procedure SetStatus(const AMsg: string; APct: Integer);
    procedure AddResultRow(const AFile, AIn, AOut, APeople, AStatus: string);
    procedure OnWorkerDone(AStopped: Boolean);
  end;

var
  MainForm: TMainForm;

implementation

uses about_unit;

{$R *.lfm}

const
  VIDEO_EXT = '*.mp4;*.mkv;*.mov;*.avi;*.mts';

function GetTokenValue(const ALine, AKey: string): Integer;
var
  p: Integer;
  val: string;
begin
  Result := -1;
  p := Pos(AKey + '=', ALine);
  if p = 0 then Exit;
  val := Copy(ALine, p + Length(AKey) + 1, MaxInt);
  p := Pos(' ', val);
  if p > 0 then val := Copy(val, 1, p - 1);
  Result := StrToIntDef(Trim(val), -1);
end;

{ ---------------- TWorkerThread ---------------- }

constructor TWorkerThread.Create(AOwner: TMainForm; const AExePath, AMode: string;
  ABaseArgs, AFiles: TStringList);
begin
  inherited Create(True);
  FOwner := AOwner;
  FExePath := AExePath;
  FMode := AMode;
  FBaseArgs := ABaseArgs;
  FFiles := AFiles;
  FStop := False;
  FreeOnTerminate := True;
  Start;
end;

destructor TWorkerThread.Destroy;
begin
  FBaseArgs.Free;
  FFiles.Free;
  inherited Destroy;
end;

procedure TWorkerThread.RequestStop;
begin
  FStop := True;
end;

procedure TWorkerThread.DoLog;
begin
  FOwner.AppendLog(FLogMsg);
end;

procedure TWorkerThread.DoStatus;
begin
  FOwner.SetStatus(FStatusMsg, FPct);
end;

procedure TWorkerThread.DoRow;
begin
  FOwner.AddResultRow(FRowFile, FRowIn, FRowOut, FRowPeople, FRowStatus);
end;

procedure TWorkerThread.DoDone;
begin
  FOwner.OnWorkerDone(FStop);
end;

procedure TWorkerThread.DrainOutput(AProcess: TProcess);
var
  n: Integer;
  s: string;
begin
  while AProcess.Output.NumBytesAvailable > 0 do
  begin
    n := AProcess.Output.NumBytesAvailable;
    if n > 4096 then n := 4096;
    SetLength(s, n);
    AProcess.Output.ReadBuffer(s[1], n);
    FLogMsg := s;
    Synchronize(@DoLog);
  end;
end;

function TWorkerThread.ParseCounters(const AFile: string;
  out AIn, AOut, APeople: Integer): Boolean;
var
  SL: TStringList;
  l, s: string;
begin
  Result := False;
  AIn := -1;
  AOut := -1;
  APeople := -1;
  if not FileExists(AFile) then Exit;
  SL := TStringList.Create;
  try
    SL.LoadFromFile(AFile);
    for l in SL do
    begin
      s := Trim(l);
      if Pos('people=', s) = 1 then
        APeople := GetTokenValue(s, 'people')
      else if Pos('in=', s) = 1 then
      begin
        AIn := GetTokenValue(s, 'in');
        AOut := GetTokenValue(s, 'out');
      end;
    end;
  finally
    SL.Free;
  end;
  Result := (APeople >= 0) or (AIn >= 0);
end;

procedure TWorkerThread.RunOneFile(const AFile: string);
var
  AProcess: TProcess;
  counterFile: string;
  code: Integer;
  inN, outN, peopleN: Integer;
  ok: Boolean;
begin
  AProcess := TProcess.Create(nil);
  try
    AProcess.Executable := FExePath;
    AProcess.Parameters.Add('--source');
    AProcess.Parameters.Add(AFile);
    AProcess.Parameters.AddStrings(FBaseArgs);
    AProcess.CurrentDirectory := ExtractFilePath(AFile);
    AProcess.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    try
      AProcess.Execute;
    except
      on E: Exception do
      begin
        FLogMsg := 'Failed to start counter.exe: ' + E.Message + LineEnding;
        Synchronize(@DoLog);
        FRowFile := AFile;
        FRowIn := '';
        FRowOut := '';
        FRowPeople := '';
        FRowStatus := 'ERROR: start failed';
        Synchronize(@DoRow);
        Exit;
      end;
    end;
    while AProcess.Running or (AProcess.Output.NumBytesAvailable > 0) do
    begin
      if FStop then
        AProcess.Terminate(1);
      DrainOutput(AProcess);
      if FStop and (not AProcess.Running) then Break;
      Sleep(5);
    end;
    AProcess.WaitOnExit;
    code := AProcess.ExitCode;
    DrainOutput(AProcess);
  finally
    AProcess.Free;
  end;

  counterFile := ChangeFileExt(AFile, '') + '_counter.txt';
  ok := ParseCounters(counterFile, inN, outN, peopleN);
  FRowFile := AFile;
  if ok and (code = 0) then
  begin
    FRowStatus := 'OK';
    if FMode = 'appear' then
    begin
      FRowIn := '';
      FRowOut := '';
      FRowPeople := IntToStr(peopleN);
    end
    else
    begin
      FRowIn := IntToStr(inN);
      FRowOut := IntToStr(outN);
      FRowPeople := '';
    end;
  end
  else
  begin
    FRowStatus := 'ERROR (' + IntToStr(code) + ')';
    FRowIn := '';
    FRowOut := '';
    FRowPeople := '';
  end;
  Synchronize(@DoRow);
end;

procedure TWorkerThread.Execute;
var
  i: Integer;
begin
  for i := 0 to FFiles.Count - 1 do
  begin
    if FStop then Break;
    FCurrentFile := FFiles[i];
    FPct := Round((i / FFiles.Count) * 100);
    FStatusMsg := 'Processing ' + ExtractFileName(FCurrentFile) + ' ...';
    Synchronize(@DoStatus);
    FLogMsg := '===== ' + FCurrentFile + ' =====' + LineEnding;
    Synchronize(@DoLog);
    RunOneFile(FCurrentFile);
  end;
  FPct := 100;
  if FStop then
    FStatusMsg := 'Stopped by user.'
  else
    FStatusMsg := 'Done.';
  Synchronize(@DoStatus);
  Synchronize(@DoDone);
end;

{ ---------------- TMainForm ---------------- }

function TMainForm.CounterFileFor(const AFile: string): string;
begin
  Result := ChangeFileExt(AFile, '') + '_counter.txt';
end;

function TMainForm.BuildBaseArgs: TStringList;
var
  args: TStringList;
  s: string;
begin
  args := TStringList.Create;
  args.Add('--mode');
  args.Add(LowerCase(rgMode.Items[rgMode.ItemIndex]));
  args.Add('--model');
  args.Add(Trim(cbModel.Text));

  s := Trim(cbDevice.Text);
  if (s <> '') and (LowerCase(s) <> 'auto') then
  begin
    args.Add('--device');
    args.Add(s);
  end;

  s := cbTracker.Text;
  if (s <> '') and (LowerCase(s) <> 'auto') then
  begin
    s := ResolveTrackerPath;
    if s <> '' then
    begin
      args.Add('--tracker');
      args.Add(s);
    end;
  end;

  if seMaxFrames.Value > 0 then
  begin
    args.Add('--max-frames');
    args.Add(IntToStr(seMaxFrames.Value));
  end;

  if rgMode.ItemIndex = 1 then
  begin
    s := Trim(edAppearSeconds.Text);
    if s <> '' then
    begin
      args.Add('--appear-seconds');
      args.Add(s);
    end;
    s := Trim(edMergeSeconds.Text);
    if s <> '' then
    begin
      args.Add('--merge-seconds');
      args.Add(s);
    end;
    s := Trim(edMergeGap.Text);
    if s <> '' then
    begin
      args.Add('--merge-gap');
      args.Add(s);
    end;
  end
  else
  begin
    args.Add('--line');
    args.Add(FormatFloat('0.###', fseLine.Value));
    args.Add('--line-axis');
    args.Add(LowerCase(rgLineAxis.Items[rgLineAxis.ItemIndex]));
    s := cbInDir.Text;
    if (s <> '') and (LowerCase(s) <> 'auto') then
    begin
      args.Add('--in-direction');
      args.Add(s);
    end;
    args.Add('--count');
    args.Add(LowerCase(cbCount.Text));
  end;

  args.Add('--conf');
  args.Add(FormatFloat('0.##', fseConf.Value));

  if fseMinSize.Value > 0 then
  begin
    args.Add('--min-size');
    args.Add(FormatFloat('0.###', fseMinSize.Value));
  end;

  if seImgsz.Value <> 640 then
  begin
    args.Add('--imgsz');
    args.Add(IntToStr(seImgsz.Value));
  end;

  if seStride.Value > 1 then
  begin
    args.Add('--stride');
    args.Add(IntToStr(seStride.Value));
  end;

  if chkHalf.Checked then args.Add('--half');
  if chkSave.Checked then args.Add('--save');
  if chkNoSnapshots.Checked then args.Add('--no-snapshots');
  if chkRtspTcp.Checked then args.Add('--rtsp-tcp');
  if chkShow.Checked and (rgSource.ItemIndex = 0) then args.Add('--show');

  Result := args;
end;

function TMainForm.ResolveTrackerPath: string;
var
  exeDir: string;
begin
  Result := '';
  exeDir := ExtractFilePath(Trim(edExePath.Text));
  if exeDir = '' then Exit;
  Result := exeDir + '_internal' + PathDelim + 'cfg' + PathDelim + 'bytetrack_strong.yaml';
  if not FileExists(Result) then Result := '';
end;

function TMainForm.BuildFileList: TStringList;
var
  list: TStringList;
  src: string;
begin
  list := TStringList.Create;
  src := Trim(edSource.Text);
  if rgSource.ItemIndex = 0 then
  begin
    if FileExists(src) then
      list.Add(src)
    else
    begin
      MessageDlg('File not found:' + LineEnding + src, mtError, [mbOK], 0);
      list.Free;
      Result := nil;
      Exit;
    end;
  end
  else
  begin
    if not DirectoryExists(src) then
    begin
      MessageDlg('Folder not found:' + LineEnding + src, mtError, [mbOK], 0);
      list.Free;
      Result := nil;
      Exit;
    end;
    list := FindAllFiles(src, VIDEO_EXT, False);
  end;
  if list.Count = 0 then
  begin
    MessageDlg('No video files found in the selected source.', mtInformation, [mbOK], 0);
    list.Free;
    Result := nil;
    Exit;
  end;
  Result := list;
end;

procedure TMainForm.SetControlsEnabled(AEnabled: Boolean);
begin
  btnRun.Enabled := AEnabled;
  btnStop.Enabled := not AEnabled;
  edSource.Enabled := AEnabled;
  btnBrowse.Enabled := AEnabled;
  rgSource.Enabled := AEnabled;
  edExePath.Enabled := AEnabled;
  btnExeBrowse.Enabled := AEnabled;
  btnExportCsv.Enabled := AEnabled;
end;

procedure TMainForm.UpdateModeUI;
begin
  gbLine.Enabled := (rgMode.ItemIndex = 0);
  gbAppear.Enabled := (rgMode.ItemIndex = 1);
end;

procedure TMainForm.AppendLog(const AText: string);
begin
  if AText <> '' then
    mmLog.Lines.Add(AText);
end;

procedure TMainForm.SetStatus(const AMsg: string; APct: Integer);
begin
  lblStatus.Caption := AMsg;
  pbProgress.Position := APct;
end;

procedure TMainForm.AddResultRow(const AFile, AIn, AOut, APeople, AStatus: string);
var
  r: Integer;
begin
  with sgResults do
  begin
    RowCount := RowCount + 1;
    r := RowCount - 1;
    Cells[0, r] := ExtractFileName(AFile);
    Cells[1, r] := rgMode.Items[rgMode.ItemIndex];
    Cells[2, r] := AIn;
    Cells[3, r] := AOut;
    Cells[4, r] := APeople;
    Cells[5, r] := AStatus;
  end;
  UpdateSummary;
end;

procedure TMainForm.UpdateSummary;
var
  i, nIn, nOut, nPeople, nFiles: Integer;
  v: Integer;
begin
  nIn := 0;
  nOut := 0;
  nPeople := 0;
  nFiles := 0;
  for i := 1 to sgResults.RowCount - 1 do
  begin
    if sgResults.Cells[5, i] <> 'OK' then Continue;
    Inc(nFiles);
    if rgMode.ItemIndex = 1 then
    begin
      v := StrToIntDef(sgResults.Cells[4, i], 0);
      Inc(nPeople, v);
    end
    else
    begin
      v := StrToIntDef(sgResults.Cells[2, i], 0);
      Inc(nIn, v);
      v := StrToIntDef(sgResults.Cells[3, i], 0);
      Inc(nOut, v);
    end;
  end;
  if rgMode.ItemIndex = 1 then
    lblSummary.Caption := Format(
      'Summary: Files OK: %d | Mode: appear | People: %d',
      [nFiles, nPeople])
  else
    lblSummary.Caption := Format(
      'Summary: Files OK: %d | In: %d | Out: %d | Total: %d',
      [nFiles, nIn, nOut, nIn + nOut]);
end;

procedure TMainForm.OnWorkerDone(AStopped: Boolean);
begin
  FWorker := nil;
  SetControlsEnabled(True);
  UpdateModeUI;
  pbProgress.Position := 100;
  if AStopped then
    lblStatus.Caption := 'Stopped by user.'
  else
    lblStatus.Caption := 'Done.';
end;

procedure TMainForm.StartRun;
var
  files, baseArgs: TStringList;
  exePath: string;
begin
  exePath := Trim(edExePath.Text);
  if exePath = '' then
  begin
    MessageDlg('Please select counter.exe first.', mtError, [mbOK], 0);
    Exit;
  end;
  if not FileExists(exePath) then
  begin
    MessageDlg('counter.exe not found:' + LineEnding + exePath, mtError, [mbOK], 0);
    Exit;
  end;
  if rgMode.ItemIndex = 1 then
  begin
    if Trim(edAppearSeconds.Text) = '' then edAppearSeconds.Text := '';
  end;

  files := BuildFileList;
  if files = nil then Exit;

  SaveSettings;
  baseArgs := BuildBaseArgs;

  mmLog.Clear;
  sgResults.RowCount := 1;
  lblSummary.Caption := '';
  lblStatus.Caption := 'Starting...';
  pbProgress.Position := 0;

  SetControlsEnabled(False);
  FWorker := TWorkerThread.Create(Self, exePath,
    LowerCase(rgMode.Items[rgMode.ItemIndex]), baseArgs, files);
end;

procedure TMainForm.StopRun;
begin
  if FWorker <> nil then
    FWorker.RequestStop;
  btnStop.Enabled := False;
  lblStatus.Caption := 'Stopping...';
end;

procedure TMainForm.LoadSettings;
begin
  FIni := TIniFile.Create(ChangeFileExt(Application.ExeName, '') + '.ini');
  edExePath.Text := FIni.ReadString('settings', 'exe', '');
  edSource.Text := FIni.ReadString('settings', 'lastsingle', '');
  rgSource.ItemIndex := FIni.ReadInteger('settings', 'srcmode', 0);
  cbModel.Text := FIni.ReadString('settings', 'model', 'yolov8n.pt');
  cbDevice.Text := FIni.ReadString('settings', 'device', 'auto');
  cbTracker.Text := FIni.ReadString('settings', 'tracker', 'auto');
  seMaxFrames.Value := FIni.ReadInteger('settings', 'maxframes', 0);
  rgMode.ItemIndex := FIni.ReadInteger('settings', 'mode', 0);
  fseLine.Value := FIni.ReadFloat('settings', 'line', 0.5);
  rgLineAxis.ItemIndex := FIni.ReadInteger('settings', 'lineaxis', 0);
  cbInDir.Text := FIni.ReadString('settings', 'indirection', 'auto');
  cbCount.Text := FIni.ReadString('settings', 'count', 'both');
  edAppearSeconds.Text := FIni.ReadString('settings', 'appearseconds', '0.25');
  edMergeSeconds.Text := FIni.ReadString('settings', 'mergeseconds', '0.8');
  edMergeGap.Text := FIni.ReadString('settings', 'mergegap', '');
  fseConf.Value := FIni.ReadFloat('settings', 'conf', 0.25);
  fseMinSize.Value := FIni.ReadFloat('settings', 'minsize', 0.0);
  seImgsz.Value := FIni.ReadInteger('settings', 'imgsz', 640);
  seStride.Value := FIni.ReadInteger('settings', 'stride', 1);
  chkHalf.Checked := FIni.ReadBool('settings', 'half', False);
  chkSave.Checked := FIni.ReadBool('settings', 'save', False);
  chkNoSnapshots.Checked := FIni.ReadBool('settings', 'nosnapshots', False);
  chkShow.Checked := FIni.ReadBool('settings', 'show', False);
  chkRtspTcp.Checked := FIni.ReadBool('settings', 'rtsptcp', False);
  UpdateModeUI;
  rgSourceClick(nil);
end;

procedure TMainForm.SaveSettings;
begin
  FIni.WriteString('settings', 'exe', Trim(edExePath.Text));
  FIni.WriteString('settings', 'lastsingle', Trim(edSource.Text));
  FIni.WriteInteger('settings', 'srcmode', rgSource.ItemIndex);
  FIni.WriteString('settings', 'model', Trim(cbModel.Text));
  FIni.WriteString('settings', 'device', Trim(cbDevice.Text));
  FIni.WriteString('settings', 'tracker', cbTracker.Text);
  FIni.WriteInteger('settings', 'maxframes', seMaxFrames.Value);
  FIni.WriteInteger('settings', 'mode', rgMode.ItemIndex);
  FIni.WriteFloat('settings', 'line', fseLine.Value);
  FIni.WriteInteger('settings', 'lineaxis', rgLineAxis.ItemIndex);
  FIni.WriteString('settings', 'indirection', cbInDir.Text);
  FIni.WriteString('settings', 'count', cbCount.Text);
  FIni.WriteString('settings', 'appearseconds', Trim(edAppearSeconds.Text));
  FIni.WriteString('settings', 'mergeseconds', Trim(edMergeSeconds.Text));
  FIni.WriteString('settings', 'mergegap', Trim(edMergeGap.Text));
  FIni.WriteFloat('settings', 'conf', fseConf.Value);
  FIni.WriteFloat('settings', 'minsize', fseMinSize.Value);
  FIni.WriteInteger('settings', 'imgsz', seImgsz.Value);
  FIni.WriteInteger('settings', 'stride', seStride.Value);
  FIni.WriteBool('settings', 'half', chkHalf.Checked);
  FIni.WriteBool('settings', 'save', chkSave.Checked);
  FIni.WriteBool('settings', 'nosnapshots', chkNoSnapshots.Checked);
  FIni.WriteBool('settings', 'show', chkShow.Checked);
  FIni.WriteBool('settings', 'rtsptcp', chkRtspTcp.Checked);
  FIni.UpdateFile;
end;

procedure TMainForm.FormCreate(Sender: TObject);
begin
  cbModel.Items.Add('yolov8n.pt');
  cbModel.Items.Add('yolov8m.pt');
  cbModel.Items.Add('yolo26x.pt');
  cbModel.Text := 'yolov8n.pt';

  cbDevice.Items.Add('auto');
  cbDevice.Items.Add('0');
  cbDevice.Items.Add('cuda:0');
  cbDevice.Items.Add('cpu');
  cbDevice.Text := 'auto';

  cbTracker.Items.Add('auto');
  cbTracker.Items.Add('bytetrack_strong');
  cbTracker.Text := 'auto';

  cbInDir.Items.Add('auto');
  cbInDir.Items.Add('top-to-bottom');
  cbInDir.Items.Add('bottom-to-top');
  cbInDir.Items.Add('left-to-right');
  cbInDir.Items.Add('right-to-left');
  cbInDir.Text := 'auto';

  cbCount.Items.Add('both');
  cbCount.Items.Add('in');
  cbCount.Items.Add('out');
  cbCount.Text := 'both';

  fseLine.MinValue := 0;
  fseLine.MaxValue := 1;
  fseLine.Increment := 0.05;
  fseLine.DecimalPlaces := 2;
  fseLine.Value := 0.5;

  fseConf.MinValue := 0;
  fseConf.MaxValue := 1;
  fseConf.Increment := 0.05;
  fseConf.DecimalPlaces := 2;
  fseConf.Value := 0.25;

  fseMinSize.MinValue := 0;
  fseMinSize.MaxValue := 1;
  fseMinSize.Increment := 0.01;
  fseMinSize.DecimalPlaces := 3;
  fseMinSize.Value := 0;

  seImgsz.MinValue := 64;
  seImgsz.MaxValue := 1280;
  seImgsz.Value := 640;

  seStride.MinValue := 1;
  seStride.MaxValue := 10;
  seStride.Value := 1;

  seMaxFrames.MinValue := 0;
  seMaxFrames.Value := 0;

  with sgResults do
  begin
    ColCount := 6;
    FixedCols := 0;
    RowCount := 1;
    FixedRows := 1;
    Cells[0, 0] := 'File';
    Cells[1, 0] := 'Mode';
    Cells[2, 0] := 'In';
    Cells[3, 0] := 'Out';
    Cells[4, 0] := 'People';
    Cells[5, 0] := 'Status';
    ColWidths[0] := 300;
    ColWidths[1] := 70;
    ColWidths[2] := 60;
    ColWidths[3] := 60;
    ColWidths[4] := 80;
    ColWidths[5] := 120;
  end;

  FWorker := nil;
  LoadSettings;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  FIni.Free;
end;

procedure TMainForm.btnBrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
  dlgDir: TSelectDirectoryDialog;
begin
  if rgSource.ItemIndex = 0 then
  begin
    dlg := TOpenDialog.Create(nil);
    try
      dlg.Title := 'Select video file';
      dlg.Filter := 'Video files|*.mp4;*.mkv;*.mov;*.avi;*.mts|All files|*.*';
      if dlg.Execute then
        edSource.Text := dlg.FileName;
    finally
      dlg.Free;
    end;
  end
  else
  begin
    dlgDir := TSelectDirectoryDialog.Create(nil);
    try
      dlgDir.Title := 'Select folder with videos';
      if dlgDir.Execute then
        edSource.Text := dlgDir.FileName;
    finally
      dlgDir.Free;
    end;
  end;
end;

procedure TMainForm.btnExeBrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(nil);
  try
    dlg.Title := 'Select counter.exe';
    dlg.Filter := 'counter.exe|counter.exe|Executables|*.exe';
    if dlg.Execute then
      edExePath.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.btnModelBrowseClick(Sender: TObject);
var
  dlg: TOpenDialog;
begin
  dlg := TOpenDialog.Create(nil);
  try
    dlg.Title := 'Select YOLO model (.pt)';
    dlg.Filter := 'YOLO model|*.pt|All files|*.*';
    if dlg.Execute then
      cbModel.Text := dlg.FileName;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.btnRunClick(Sender: TObject);
begin
  StartRun;
end;

procedure TMainForm.btnStopClick(Sender: TObject);
begin
  StopRun;
end;

procedure TMainForm.btnExportCsvClick(Sender: TObject);
var
  dlg: TSaveDialog;
  SL: TStringList;
  i: Integer;
begin
  if sgResults.RowCount <= 1 then
  begin
    MessageDlg('Nothing to export yet.', mtInformation, [mbOK], 0);
    Exit;
  end;
  dlg := TSaveDialog.Create(nil);
  try
    dlg.Title := 'Export results';
    dlg.Filter := 'CSV files|*.csv|All files|*.*';
    dlg.DefaultExt := '.csv';
    dlg.FileName := 'counter_results.csv';
    if not dlg.Execute then Exit;
    SL := TStringList.Create;
    try
      SL.Add('File,Mode,In,Out,People,Status');
      for i := 1 to sgResults.RowCount - 1 do
        SL.Add(Format('"%s",%s,%s,%s,%s,%s',
          [sgResults.Cells[0, i], sgResults.Cells[1, i],
           sgResults.Cells[2, i], sgResults.Cells[3, i],
           sgResults.Cells[4, i], sgResults.Cells[5, i]]));
      SL.Add('');
      SL.Add(lblSummary.Caption);
      SL.SaveToFile(dlg.FileName);
    finally
      SL.Free;
    end;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.btnAboutClick(Sender: TObject);
begin
  AboutForm.ShowModal;
end;

procedure TMainForm.rgModeClick(Sender: TObject);
begin
  UpdateModeUI;
end;

procedure TMainForm.rgSourceClick(Sender: TObject);
begin
  chkShow.Enabled := (rgSource.ItemIndex = 0);
  if rgSource.ItemIndex <> 0 then
    chkShow.Checked := False;
end;

end.