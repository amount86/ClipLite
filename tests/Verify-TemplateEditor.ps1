$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\ClipLite.ps1'),[ref]$tokens,[ref]$errors)
$theme=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:Theme'},$true)
. ([scriptblock]::Create($theme.Extent.Text))
foreach($name in @('New-FlatButton','Show-TemplateEditor')){
 $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
 . ([scriptblock]::Create($node.Extent.Text))
}
$script:Form=New-Object System.Windows.Forms.Form
$script:Form.Font=New-Object System.Drawing.Font('Yu Gothic UI',9.5)
$script:Failure=$null
$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=150
$timer.Add_Tick({
 $timer.Stop()
 $d=@([System.Windows.Forms.Application]::OpenForms | Where-Object Text -Match '^定型文を')[0]
 try {
  if($d.FormBorderStyle -ne 'None' -or $d.BackColor -ne $script:Theme.Back){throw 'Theme mismatch'}
  $boxes=@($d.Controls | Where-Object {$_ -is [System.Windows.Forms.TextBox]})
  $name=$boxes | Where-Object AccessibleName -eq '定型文の名前'
  $body=$boxes | Where-Object AccessibleName -eq '定型文の本文'
  $save=$d.Controls | Where-Object Text -eq '保存'
  $cancel=$d.Controls | Where-Object Text -eq 'キャンセル'
  foreach($c in $d.Controls){if($c.Right -gt $d.ClientSize.Width -or $c.Bottom -gt $d.ClientSize.Height){throw ('Control outside dialog: '+$c.Text+' '+$c.Bounds+' client '+$d.ClientSize)}}
  if(-not $save.TabStop -or -not $cancel.TabStop){throw 'Button keyboard navigation disabled'}
  if($script:Case -eq 'add'){
   $save.PerformClick()
   if($d.DialogResult -eq 'OK'){throw 'Empty input accepted'}
   $name.Text='テスト定型文';$body.Text="本文`r`n{{DATE}}"
   $save.PerformClick()
  }elseif($script:Case -eq 'edit'){
   if($name.Text -ne '既存' -or $body.Text -ne '既存本文'){throw 'Existing values not loaded'}
   $body.Text='更新本文';$save.PerformClick()
  }else{$cancel.PerformClick()}
 }catch{$script:Failure=$_.Exception.Message;$d.Close()}
})
try {
 foreach($script:Case in @('add','edit','cancel')){
  $timer.Start()
  $item=if($script:Case -eq 'edit'){[pscustomobject]@{Name='既存';Text='既存本文'}}else{$null}
  $result=Show-TemplateEditor $item
  if($script:Failure){throw $script:Failure}
  if($script:Case -eq 'add' -and ($result.Name -ne 'テスト定型文' -or $result.Text -ne "本文`r`n{{DATE}}")){throw 'Add result mismatch'}
  if($script:Case -eq 'edit' -and $result.Text -ne '更新本文'){throw 'Edit result mismatch'}
  if($script:Case -eq 'cancel' -and $null -ne $result){throw 'Cancel returned data'}
  if($script:IsModalOpen){throw 'Modal flag not cleared'}
 }
 'PASS: dialog theme, bounds, validation, add/edit/cancel, modal cleanup.'
}finally{$timer.Dispose();$script:Form.Dispose()}
