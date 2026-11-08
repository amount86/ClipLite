$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$source = Join-Path $PSScriptRoot '..\ClipLite.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Assert-Config','Write-AtomicUtf8')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$configPath=Join-Path $PSScriptRoot '..\config.example.json'
Assert-Config (Get-Content $configPath -Raw | ConvertFrom-Json)
foreach ($value in @(-1,0,1001,'100',$true,1.5)) {
    $c=Get-Content $configPath -Raw | ConvertFrom-Json
    $c.MaxHistory=$value
    $rejected=$false
    try { Assert-Config $c } catch { $rejected=$true }
    if (-not $rejected) { throw 'Invalid MaxHistory accepted' }
}
$c=Get-Content $configPath -Raw | ConvertFrom-Json
$c.AutoPaste='false'
try { Assert-Config $c; throw 'TEST_FAILURE' } catch { if ($_.Exception.Message -eq 'TEST_FAILURE') { throw } }
$testPath=Join-Path $PSScriptRoot 'atomic-test.json'
try {
    Write-AtomicUtf8 $testPath 'first'
    Write-AtomicUtf8 $testPath 'second'
    if ([IO.File]::ReadAllText($testPath) -ne 'second') { throw 'Atomic replacement failed' }
    $lock=[IO.File]::Open($testPath,'Open','Read','None')
    try { Write-AtomicUtf8 $testPath 'lost'; throw 'TEST_FAILURE' } catch { if ($_.Exception.Message -eq 'TEST_FAILURE') { throw } } finally { $lock.Dispose() }
    if ([IO.File]::ReadAllText($testPath) -ne 'second') { throw 'Original lost on failed save' }
    if (@(Get-ChildItem $PSScriptRoot -Filter 'atomic-test.json.*.tmp').Count) { throw 'Temporary file leaked' }
} finally { if (Test-Path $testPath) { Remove-Item -LiteralPath $testPath } }
$csharpNode=$ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$csharp'},$true)
$csharp=$csharpNode.Right.Expression.Value
Add-Type -TypeDefinition $csharp -Language CSharp -ReferencedAssemblies System.dll,System.Windows.Forms.dll
[ClipLite.Native.FocusHelper]::SendCtrlV([IntPtr]::Zero)
'PASS: PowerShell parse, config validation, atomic replacement/failure preservation, C# compilation, no-target paste cancellation.'
