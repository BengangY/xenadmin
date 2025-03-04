# Copyright (c) Cloud Software Group, Inc.
#
# Redistribution and use in source and binary forms,
# with or without modification, are permitted provided
# that the following conditions are met:
#
# *   Redistributions of source code must retain the above
#     copyright notice, this list of conditions and the
#     following disclaimer.
# *   Redistributions in binary form must reproduce the above
#     copyright notice, this list of conditions and the
#     following disclaimer in the documentation and/or other
#     materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
# CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

Param(
    [Parameter(HelpMessage = "Global build number", Mandatory = $true)]
    [int]$buildNumber,

    [Parameter(HelpMessage = "Thumbprint of the certificate to use for signing")]
    [string]$thumbPrint,

    [Parameter(HelpMessage = "Timestamp server to use for signing")]
    [string]$timestampServer
)

$verbose = $false
if ($PSBoundParameters.ContainsKey('Verbose')) {
    $verbose = $PsBoundParameters['Verbose']
}

$ErrorActionPreference = "Stop"

####################
# Helper functions #
####################

function mkdir_clean([string]$path) {
    if ([System.IO.Directory]::Exists($path)) {
        Remove-Item -Path $path -Force -Recurse -Verbose:$verbose
    }
    New-Item -ItemType Directory -Path $path -Verbose:$verbose
}

function build([string]$solution) {
    msbuild /m /verbosity:minimal /p:Configuration=Release /p:TargetFrameworkVersion=v4.8 /p:VisualStudioVersion=17.0 $solution
}

function get_locale_id([string]$locale) {
    switch ($locale) {
        "ja-jp" { 1041 }
        "zh-cn" { 2052 }
        "zh-tw" { 1028 }
        default { 1033 } #en-us
    }
}

######################
# clean working area #
######################

$REPO = Get-Item "$PSScriptRoot\.." | Select-Object -ExpandProperty FullName
$SCRATCH_DIR="$REPO\_scratch"
$OUTPUT_DIR="$REPO\_output"

Write-Host "INFO: Cleaning scratch and output directories"
mkdir_clean $SCRATCH_DIR
mkdir_clean $OUTPUT_DIR

. $REPO\scripts\branding.ps1
$appName =  $BRANDING_BRAND_CONSOLE

############################################
# package sources BEFORE applying branding #
############################################

Write-Host "INFO: Packaging source files"

$gitCommit = git rev-parse HEAD
git archive --format=zip -o "$SCRATCH_DIR\xenadmin-sources.zip" $gitCommit

Compress-Archive -Path "$SCRATCH_DIR\xenadmin-sources.zip","$REPO\packages\dotnet-packages-sources.zip" `
    -DestinationPath "$OUTPUT_DIR\$appName-source.zip" -Verbose:$verbose

##################
# apply branding #
##################

.$REPO\scripts\rebranding.ps1 $buildNumber -Verbose:$verbose

Write-Host "INFO: Expanding External Tools"
Expand-Archive -Path $REPO\packages\XenCenterOVF.zip -DestinationPath $SCRATCH_DIR -Verbose:$verbose

Write-Host "INFO: Building solution"
build $REPO\XenAdmin.sln

##############
# sign files #
##############

if ([System.IO.File]::Exists("$REPO\scripts\sign.ps1")) {
    . $REPO\scripts\sign.ps1

    $filesToSign = @(
        "$REPO\XenAdmin\bin\Release\CommandLib.dll",
        "$REPO\XenAdmin\bin\Release\MSTSCLib.dll",
        "$REPO\XenAdmin\bin\Release\CoreUtilsLib.dll",
        "$REPO\XenAdmin\bin\Release\XenModel.dll",
        "$REPO\XenAdmin\bin\Release\XenOvf.dll",
        "$REPO\XenAdmin\bin\Release\$appName.exe",
        "$REPO\xe\bin\Release\xe.exe",
        "$REPO\XenAdmin\ReportViewer\Microsoft.ReportViewer.Common.dll",
        "$REPO\XenAdmin\ReportViewer\Microsoft.ReportViewer.ProcessingObjectModel.dll",
        "$REPO\XenAdmin\ReportViewer\Microsoft.ReportViewer.WinForms.dll",
        "$REPO\XenAdmin\ReportViewer\Microsoft.ReportViewer.Common.resources.dll",
        "$REPO\XenAdmin\ReportViewer\Microsoft.ReportViewer.WinForms.resources.dll"
    )

    foreach ($file in $filesToSign) {
        sign_artifact $file $appName $thumbPrint $timestampServer
    }

    sign_artifact $REPO\XenAdmin\bin\Release\CookComputing.XmlRpcV2.dll "XML-RPC.NET" $thumbPrint $timestampServer
    sign_artifact $REPO\XenAdmin\bin\Release\Newtonsoft.Json.CH.dll "JSON.NET" $thumbPrint $timestampServer
    sign_artifact $REPO\XenAdmin\bin\Release\log4net.dll "Log4Net" $thumbPrint $timestampServer
    sign_artifact $REPO\XenAdmin\bin\Release\ICSharpCode.SharpZipLib.dll "SharpZipLib" $thumbPrint $timestampServer
    sign_artifact $REPO\XenAdmin\bin\Release\DiscUtils.dll "DiscUtils" $thumbPrint $timestampServer

}
else {
    Write-Host "INFO: Sign script does not exist; skip signing binaries"
}

###############
# prepare Wix #
###############

Write-Host "INFO: Preparing Wix binaries and UI sources"
mkdir_clean $SCRATCH_DIR\wixbin
Expand-Archive -Path $REPO\packages\wix311-binaries.zip -DestinationPath $SCRATCH_DIR\wixbin
mkdir_clean $SCRATCH_DIR\wixsrc
Expand-Archive -Path $REPO\packages\wix311-debug.zip -DestinationPath $SCRATCH_DIR\wixsrc

Copy-Item -Recurse $REPO\WixInstaller $SCRATCH_DIR -Verbose:$verbose
Copy-Item -Recurse $SCRATCH_DIR\wixsrc\src\ext\UIExtension\wixlib $SCRATCH_DIR\WixInstaller -Verbose:$verbose
Copy-Item $SCRATCH_DIR\WixInstaller\wixlib\CustomizeDlg.wxs $SCRATCH_DIR\WixInstaller\wixlib\CustomizeStdDlg.wxs -Verbose:$verbose

if ("XenCenter" -ne $appName) {
    Rename-Item -Path $SCRATCH_DIR\WixInstaller\XenCenter.wxs -NewName "$appName.wxs" -Verbose:$verbose
}

$origLocation = Get-Location
Set-Location $SCRATCH_DIR\WixInstaller\wixlib -Verbose:$verbose
try {
    Write-Host "INFO: Patching Wix UI library"
    git apply --verbose $SCRATCH_DIR\WixInstaller\wix_src.patch
    Write-Host "INFO: Patching Wix UI library completed"
}
finally {
    Set-Location $origLocation -Verbose:$verbose
}

New-Item -ItemType File -Path $SCRATCH_DIR\WixInstaller\PrintEula.dll -Verbose:$verbose

###############
# compile Wix #
###############

$CANDLE="$SCRATCH_DIR\wixbin\candle.exe"
$LIT="$SCRATCH_DIR\wixbin\lit.exe"
$LIGHT="$SCRATCH_DIR\wixbin\light.exe"

$installerUiFiles = @(
    "BrowseDlg",
    "CancelDlg",
    "Common",
    "CustomizeDlg",
    "CustomizeStdDlg",
    "DiskCostDlg",
    "ErrorDlg",
    "ErrorProgressText",
    "ExitDialog",
    "FatalError",
    "FilesInUse",
    "InstallDirDlg",
    "InvalidDirDlg",
    "LicenseAgreementDlg",
    "MaintenanceTypeDlg",
    "MaintenanceWelcomeDlg",
    "MsiRMFilesInUse",
    "OutOfDiskDlg",
    "OutOfRbDiskDlg",
    "PrepareDlg",
    "ProgressDlg",
    "ResumeDlg",
    "SetupTypeDlg",
    "UserExit",
    "VerifyReadyDlg",
    "WaitForCostingDlg",
    "WelcomeDlg",
    "WixUI_InstallDir",
    "WixUI_FeatureTree"
)

$candleList = $installerUiFiles | ForEach-Object { "$SCRATCH_DIR\WixInstaller\wixlib\$_.wxs" }
$candleListString = $candleList -join " "
$litList = $installerUiFiles | ForEach-Object { "$SCRATCH_DIR\WixInstaller\wixlib\$_.wixobj" }
$litListString = $litList -join " "

$env:RepoRoot=$REPO
$env:WixLangId=get_locale_id $locale

Write-Host "INFO: Compiling Wix UI"
Invoke-Expression "$CANDLE -v -out $SCRATCH_DIR\WixInstaller\wixlib\ $candleListString"
Invoke-Expression "$LIT -v -out $SCRATCH_DIR\WixInstaller\wixlib\WixUiLibrary.wixlib $litListString"

##########################################################
# for each locale create an msi containing all resources #
##########################################################

$locales = @("en-us")

foreach ($locale in $locales) {
    if ($locale -eq "en-us") {
        $name=$appName
    }
    else {
        $name=$appName.$locale
    }

    Write-Host "INFO: Building msi installer"

    Invoke-Expression "$CANDLE -v -ext WiXNetFxExtension -ext WixUtilExtension -out $SCRATCH_DIR\WixInstaller\ $SCRATCH_DIR\WixInstaller\$appName.wxs"

    Invoke-Expression "$LIGHT -v -sval -ext WiXNetFxExtension -ext WixUtilExtension -out $SCRATCH_DIR\WixInstaller\$name.msi -loc $SCRATCH_DIR\WixInstaller\wixlib\wixui_$locale.wxl -loc $SCRATCH_DIR\WixInstaller\$locale.wxl $SCRATCH_DIR\WixInstaller\$appName.wixobj $SCRATCH_DIR\WixInstaller\wixlib\WixUiLibrary.wixlib"
}

########################################
# copy and sign the combined installer #
########################################

if ([System.IO.File]::Exists("$REPO\scripts\sign.ps1")) {
    sign_artifact "$SCRATCH_DIR\WixInstaller\$appName.msi" $appName  $thumbPrint $timestampServer
}
else {
    Write-Host "INFO: Sign script does not exist; skip signing installer"
}

Copy-Item -LiteralPath "$SCRATCH_DIR\WixInstaller\$appName.msi" $OUTPUT_DIR -Verbose:$verbose

###################
# build the tests #
###################

Write-Host "INFO: Building the tests"
build $REPO\XenAdminTests\XenAdminTests.csproj
Copy-Item $REPO\XenAdmin\ReportViewer\* $REPO\XenAdminTests\bin\Release\ -Verbose:$verbose

Compress-Archive -Path $REPO\XenAdminTests\bin\Release -DestinationPath $OUTPUT_DIR\XenAdminTests.zip -Verbose:$verbose
Compress-Archive -Path $REPO\XenAdmin\TestResources\* -DestinationPath "$OUTPUT_DIR\$($appName)TestResources.zip" -Verbose:$verbose

####################
# package the pdbs #
####################

Compress-Archive -Path $REPO\packages\*.pdb,$REPO\XenAdmin\bin\Release\*.pdb,$REPO\xe\bin\Release\xe.pdb `
    -DestinationPath "$OUTPUT_DIR\$appName.Symbols.zip" -Verbose:$verbose

################################################
# calculate installer and source zip checksums #
################################################

$msi_checksum = (Get-FileHash -LiteralPath "$OUTPUT_DIR\$appName.msi" -Algorithm SHA256 |`
    Select-Object -ExpandProperty Hash).ToLower()

$msi_checksum | Out-File -LiteralPath "$OUTPUT_DIR\$appName.msi.checksum" -Encoding utf8

Write-Host "INFO: Calculated checksum installer checksum: $msi_checksum"

$source_checksum = (Get-FileHash -LiteralPath "$OUTPUT_DIR\$appName-source.zip" -Algorithm SHA256 |`
    Select-Object -ExpandProperty Hash).ToLower()

$source_checksum | Out-File -LiteralPath "$OUTPUT_DIR\$appName-source.zip.checksum" -Encoding utf8

Write-Host "INFO: Calculated checksum source checksum: $source_checksum"

$xmlFormat=@"
<?xml version="1.0" ?>
<patchdata>
    <versions>
        <version
            latest="true"
            latestcr="true"
            name="{0}"
            timestamp="{1}"
            url="{2}"
            checksum="{3}"
            value="{4}"
            sourceUrl="{5}"
        />
    </versions>
</patchdata>
"@

$msi_url = $XC_UPDATES_URL -replace "XCUpdates.xml","$appName.msi"
$source_url = $XC_UPDATES_URL -replace "XCUpdates.xml","$appName-source.zip"
$date=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$productVersion = "$BRANDING_XC_PRODUCT_VERSION.$buildNumber"
$productFullName = "$appName $productVersion"

$prodXml = [string]::Format($xmlFormat, $productFullName, $date, $msi_url, $msi_checksum, $productVersion, $source_url)
$testXml = [string]::Format($xmlFormat, $productFullName, $date, "@DEV_MSI_URL_PLACEHOLDER@", $msi_checksum, $productVersion, "@DEV_SRC_URL_PLACEHOLDER@")

Write-Host $prodXml
Write-Host $testXml

# generate the xmls without the byte order mark because sometimes it is
# written out as a ? character in the file causing the xml to be invalid
$bomLessEncoding = New-Object System.Text.UTF8Encoding $false

Write-Host "INFO: Generating XCUpdates.xml"

[System.IO.File]::WriteAllLines("$OUTPUT_DIR\XCUpdates.xml", $prodXml, $bomLessEncoding)

Write-Host "INFO: Generating stage-test-XCUpdates.xml. URL is a placeholder value"

[System.IO.File]::WriteAllLines("$OUTPUT_DIR\stage-test-XCUpdates.xml", $testXml, $bomLessEncoding)
