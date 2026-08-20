// SPDX-License-Identifier: AGPL-3.0-or-later
unit about_unit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, LCLIntf;

type
  TAboutForm = class(TForm)
    lblTitle: TLabel;
    lblCounter: TLabel;
    lblCounterLink: TLabel;
    lblYolo: TLabel;
    lblYoloLink: TLabel;
    lblLicense: TLabel;
    btnOk: TButton;
    procedure lblCounterLinkClick(Sender: TObject);
    procedure lblYoloLinkClick(Sender: TObject);
    procedure btnOkClick(Sender: TObject);
  end;

var
  AboutForm: TAboutForm;

implementation

{$R *.lfm}

procedure TAboutForm.lblCounterLinkClick(Sender: TObject);
begin
  OpenURL('https://github.com/whacharachai/counter');
end;

procedure TAboutForm.lblYoloLinkClick(Sender: TObject);
begin
  OpenURL('https://github.com/ultralytics/ultralytics');
end;

procedure TAboutForm.btnOkClick(Sender: TObject);
begin
  Close;
end;

end.