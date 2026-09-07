#requires -Version 5.1
<#
.SYNOPSIS
    Графический менеджер зашифрованных учетных данных Windows PowerShell 5.1.

.DESCRIPTION
    Файлы сохраняются как PSCredential с помощью Export-Clixml. Пароль защищен
    механизмом DPAPI текущего пользователя Windows: файл нельзя расшифровать
    из-под другой учетной записи или на другом компьютере.
#>

Set-StrictMode -Version Latest

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:settingsPath = Join-Path -Path $script:scriptDirectory -ChildPath 'Save-Credentials.env'
$script:logsDirectory = Join-Path -Path $script:scriptDirectory -ChildPath 'logs'
$script:startTime = Get-Date
$script:logPath = $null
$script:currentFolder = $null
$script:gui_credentialsList = $null
$script:gui_logTextBox = $null
$script:gui_domainValue = $null
$script:gui_loginValue = $null
$script:gui_fileValue = $null
$script:gui_copyPasswordButton = $null
$script:gui_changePasswordButton = $null
$script:gui_deleteFileButton = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CredentialPartsFromUserName {
    param([Parameter(Mandatory = $true)][string]$UserName)

    $userName = $UserName.Trim()
    $domain = ''
    $login = $userName

    if ($userName -match '^(?<Domain>[^\\]+)\\(?<Login>.+)$') {
        $domain = $Matches.Domain
        $login = $Matches.Login
    }
    elseif ($userName -match '^(?<Login>[^@]+)@(?<Domain>.+)$') {
        $domain = $Matches.Domain
        $login = $Matches.Login
    }
    return [pscustomobject]@{
        Domain = $domain
        Login  = $login
    }
}

function Get-CredentialParts {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $parts = Get-CredentialPartsFromUserName -UserName $Credential.UserName
    $networkCredential = $Credential.GetNetworkCredential()
    if ([String]::IsNullOrWhiteSpace($parts.Domain) -and
        -not [String]::IsNullOrWhiteSpace($networkCredential.Domain)) {
        $domain = $networkCredential.Domain
        return [pscustomobject]@{
            Domain = $domain
            Login  = $networkCredential.UserName
        }
    }

    return $parts
}

function Get-CredentialPartsFromClixml {
    param([Parameter(Mandatory = $true)][string]$Path)

    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
    }
    finally {
        $reader.Dispose()
    }

    $credentialType = $document.SelectSingleNode(
        '//*[local-name()="T" and text()="System.Management.Automation.PSCredential"]'
    )
    if ($null -eq $credentialType) {
        throw 'Содержимое XML не является объектом PSCredential.'
    }

    $userNameNode = $document.SelectSingleNode('//*[local-name()="S" and @N="UserName"]')
    if ($null -eq $userNameNode -or [String]::IsNullOrWhiteSpace($userNameNode.InnerText)) {
        throw 'В XML не найдено поле UserName.'
    }

    return Get-CredentialPartsFromUserName -UserName $userNameNode.InnerText
}

function ConvertTo-SafeFileNamePart {
    param([Parameter(Mandatory = $true)][string]$Value)

    $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()
    $result = $Value
    foreach ($character in $invalidCharacters) {
        $result = $result.Replace([string]$character, '_')
    }
    return $result.Trim().TrimEnd('.')
}

function Read-Settings {
    $settings = @{}
    if (-not (Test-Path -LiteralPath $script:settingsPath -PathType Leaf)) {
        return $settings
    }

    try {
        foreach ($line in [IO.File]::ReadAllLines($script:settingsPath)) {
            if ($line -match '^\s*(#|$)') {
                continue
            }
            if ($line -match '^\s*(?<Name>[^=]+)=(?<Value>.*)$') {
                $settings[$Matches.Name.Trim()] = $Matches.Value
            }
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось прочитать файл настроек:`r`n$($_.Exception.Message)",
            'Ошибка настроек',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    return $settings
}

function Save-Settings {
    $content = @(
        '# Настройки Save-Credentials.ps1',
        '# Формат: KEY=VALUE',
        "CREDENTIALS_FOLDER=$script:currentFolder"
    ) -join [Environment]::NewLine

    try {
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($script:settingsPath, $content + [Environment]::NewLine, $encoding)
    }
    catch {
        Write-Log "Не удалось сохранить настройки: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось сохранить настройки:`r`n$($_.Exception.Message)",
            'Ошибка настроек',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)

    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    try {
        Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        # Журнал не должен останавливать работу интерфейса.
    }

    if ($null -ne $script:gui_logTextBox -and -not $script:gui_logTextBox.IsDisposed) {
        $script:gui_logTextBox.AppendText($line + [Environment]::NewLine)
        $script:gui_logTextBox.SelectionStart = $script:gui_logTextBox.TextLength
        $script:gui_logTextBox.ScrollToCaret()
    }
}

function Clear-CredentialDetails {
    $script:gui_domainValue.Text = '-'
    $script:gui_loginValue.Text = '-'
    $script:gui_fileValue.Text = '-'
    $script:gui_copyPasswordButton.Enabled = $false
    $script:gui_changePasswordButton.Enabled = $false
    $script:gui_deleteFileButton.Enabled = $false
}

function Show-CredentialDetails {
    param([Parameter(Mandatory = $true)]$ItemData)

    if (-not $ItemData.Readable) {
        Clear-CredentialDetails
        $script:gui_domainValue.Text = if ([String]::IsNullOrWhiteSpace($ItemData.Domain)) { 'Не найден' } else { $ItemData.Domain }
        $script:gui_loginValue.Text = if ([String]::IsNullOrWhiteSpace($ItemData.Login)) { 'Не найден' } else { $ItemData.Login }
        $script:gui_fileValue.Text = "$($ItemData.Name) (недоступен для чтения)"
        return
    }

    $script:gui_domainValue.Text = $ItemData.Domain
    $script:gui_loginValue.Text = $ItemData.Login
    $script:gui_fileValue.Text = $ItemData.Name
    $script:gui_copyPasswordButton.Enabled = $true
    $script:gui_changePasswordButton.Enabled = $true
}

function Get-ConfirmedNewPassword {
    param([Parameter(Mandatory = $true)][string]$FileName)

    $gui_passwordDialog = New-Object System.Windows.Forms.Form
    $gui_passwordDialog.Text = 'Изменение пароля'
    $gui_passwordDialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $gui_passwordDialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $gui_passwordDialog.ClientSize = New-Object Drawing.Size(420, 180)
    $gui_passwordDialog.MinimizeBox = $false
    $gui_passwordDialog.MaximizeBox = $false
    $gui_passwordDialog.ShowInTaskbar = $false
    $gui_passwordDialog.Font = New-Object Drawing.Font('Segoe UI', 9)

    $gui_passwordDescription = New-Object System.Windows.Forms.Label
    $gui_passwordDescription.Text = "Укажите новый пароль для файла '$FileName'.`r`nДомен и логин изменены не будут."
    $gui_passwordDescription.AutoSize = $true
    $gui_passwordDescription.Location = New-Object Drawing.Point(12, 12)

    $gui_newPasswordLabel = New-Object System.Windows.Forms.Label
    $gui_newPasswordLabel.Text = 'Новый пароль:'
    $gui_newPasswordLabel.AutoSize = $true
    $gui_newPasswordLabel.Location = New-Object Drawing.Point(12, 62)
    $gui_newPasswordTextBox = New-Object System.Windows.Forms.TextBox
    $gui_newPasswordTextBox.Location = New-Object Drawing.Point(145, 58)
    $gui_newPasswordTextBox.Size = New-Object Drawing.Size(260, 23)
    $gui_newPasswordTextBox.UseSystemPasswordChar = $true

    $gui_confirmationLabel = New-Object System.Windows.Forms.Label
    $gui_confirmationLabel.Text = 'Подтверждение:'
    $gui_confirmationLabel.AutoSize = $true
    $gui_confirmationLabel.Location = New-Object Drawing.Point(12, 94)
    $gui_confirmationTextBox = New-Object System.Windows.Forms.TextBox
    $gui_confirmationTextBox.Location = New-Object Drawing.Point(145, 90)
    $gui_confirmationTextBox.Size = New-Object Drawing.Size(260, 23)
    $gui_confirmationTextBox.UseSystemPasswordChar = $true

    $gui_savePasswordButton = New-Object System.Windows.Forms.Button
    $gui_savePasswordButton.Text = 'Сохранить пароль'
    $gui_savePasswordButton.Size = New-Object Drawing.Size(130, 28)
    $gui_savePasswordButton.Location = New-Object Drawing.Point(184, 135)
    $gui_savePasswordButton.DialogResult = [System.Windows.Forms.DialogResult]::None
    $gui_cancelPasswordButton = New-Object System.Windows.Forms.Button
    $gui_cancelPasswordButton.Text = 'Отмена'
    $gui_cancelPasswordButton.Size = New-Object Drawing.Size(90, 28)
    $gui_cancelPasswordButton.Location = New-Object Drawing.Point(315, 135)
    $gui_cancelPasswordButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    [void]$gui_passwordDialog.Controls.Add($gui_passwordDescription)
    [void]$gui_passwordDialog.Controls.Add($gui_newPasswordLabel)
    [void]$gui_passwordDialog.Controls.Add($gui_newPasswordTextBox)
    [void]$gui_passwordDialog.Controls.Add($gui_confirmationLabel)
    [void]$gui_passwordDialog.Controls.Add($gui_confirmationTextBox)
    [void]$gui_passwordDialog.Controls.Add($gui_savePasswordButton)
    [void]$gui_passwordDialog.Controls.Add($gui_cancelPasswordButton)
    $gui_passwordDialog.AcceptButton = $gui_savePasswordButton
    $gui_passwordDialog.CancelButton = $gui_cancelPasswordButton

    $gui_savePasswordButton.Add_Click({
        if ([String]::IsNullOrEmpty($gui_newPasswordTextBox.Text)) {
            [System.Windows.Forms.MessageBox]::Show(
                'Введите новый пароль.',
                'Пароль не указан',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $gui_newPasswordTextBox.Focus()
            return
        }
        if ($gui_newPasswordTextBox.Text -cne $gui_confirmationTextBox.Text) {
            [System.Windows.Forms.MessageBox]::Show(
                'Пароль и его подтверждение не совпадают.',
                'Пароли не совпадают',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $gui_confirmationTextBox.Clear()
            $gui_confirmationTextBox.Focus()
            return
        }

        $gui_passwordDialog.Tag = ConvertTo-SecureString -String $gui_newPasswordTextBox.Text -AsPlainText -Force
        $gui_passwordDialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $gui_passwordDialog.Close()
    })

    try {
        if ($gui_passwordDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $gui_passwordDialog.Tag
        }
        return $null
    }
    finally {
        $gui_newPasswordTextBox.Clear()
        $gui_confirmationTextBox.Clear()
        $gui_passwordDialog.Dispose()
    }
}

function Load-CredentialFiles {
    $script:gui_credentialsList.BeginUpdate()
    try {
        $script:gui_credentialsList.Items.Clear()
        Clear-CredentialDetails

        $files = Get-ChildItem -LiteralPath $script:currentFolder -Filter '*.xml' -File -ErrorAction Stop |
            Sort-Object -Property Name

        foreach ($file in $files) {
            $readable = $false
            $credential = $null
            $parts = $null
            try {
                $credential = Import-Clixml -LiteralPath $file.FullName -ErrorAction Stop
                if ($credential -isnot [System.Management.Automation.PSCredential]) {
                    throw 'Содержимое XML не является объектом PSCredential.'
                }
                $parts = Get-CredentialParts -Credential $credential
                $readable = $true
            }
            catch {
                $readError = $_.Exception.Message
                try {
                    $parts = Get-CredentialPartsFromClixml -Path $file.FullName
                }
                catch {
                    $parts = $null
                }
            }

            $gui_item = New-Object System.Windows.Forms.ListViewItem($file.Name)
            [void]$gui_item.SubItems.Add($(if ($readable) { 'Доступен' } else { 'Недоступен' }))
            $gui_item.Tag = [pscustomobject]@{
                Name       = $file.Name
                Path       = $file.FullName
                Readable   = $readable
                Credential = $credential
                Domain     = if ($null -ne $parts) { $parts.Domain } else { '' }
                Login      = if ($null -ne $parts) { $parts.Login } else { '' }
                Error      = if ($readable) { '' } else { $readError }
            }
            if (-not $readable) {
                $gui_item.ForeColor = [Drawing.Color]::Firebrick
                $gui_item.ToolTipText = "Недоступен для чтения: $readError"
            }
            [void]$script:gui_credentialsList.Items.Add($gui_item)
        }
    }
    catch {
        Write-Log "Не удалось прочитать папку '$script:currentFolder': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось прочитать папку:`r`n$($_.Exception.Message)",
            'Ошибка папки',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $script:gui_credentialsList.EndUpdate()
    }
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    [System.Windows.Forms.MessageBox]::Show(
        'Для работы графического интерфейса запустите скрипт в STA-режиме:' + [Environment]::NewLine +
        'powershell.exe -STA -ExecutionPolicy Bypass -File .\Save-Credentials.ps1',
        'Требуется STA-режим',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
    exit 1
}

if (-not (Test-Path -LiteralPath $script:logsDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $script:logsDirectory -Force | Out-Null
}

$script:logPath = Join-Path -Path $script:logsDirectory -ChildPath ('Save-Credentials_{0:yyyyMMdd}.log' -f $script:startTime)
$startMessage = 'Время запуска скрипта: {0:yyyy-MM-dd HH:mm:ss}' -f $script:startTime
$encoding = New-Object System.Text.UTF8Encoding($false)
if (Test-Path -LiteralPath $script:logPath -PathType Leaf) {
    [IO.File]::AppendAllText(
        $script:logPath,
        [Environment]::NewLine + $startMessage + [Environment]::NewLine,
        $encoding
    )
}
else {
    [IO.File]::WriteAllText($script:logPath, $startMessage + [Environment]::NewLine, $encoding)
}

$settings = Read-Settings
$defaultFolder = $script:scriptDirectory
if ($settings.ContainsKey('CREDENTIALS_FOLDER') -and
    (Test-Path -LiteralPath $settings['CREDENTIALS_FOLDER'] -PathType Container)) {
    $defaultFolder = $settings['CREDENTIALS_FOLDER']
}
$script:currentFolder = $defaultFolder
Save-Settings

$gui_form = New-Object System.Windows.Forms.Form
$gui_form.Text = 'Сохранение учетных данных'
$gui_form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$gui_form.Size = New-Object Drawing.Size(940, 700)
$gui_form.MinimumSize = New-Object Drawing.Size(780, 580)
$gui_form.Font = New-Object Drawing.Font('Segoe UI', 9)

$gui_rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$gui_rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$gui_rootLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$gui_rootLayout.ColumnCount = 1
$gui_rootLayout.RowCount = 6
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55)))
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45)))
$gui_form.Controls.Add($gui_rootLayout)

$gui_infoGroup = New-Object System.Windows.Forms.GroupBox
$gui_infoGroup.Text = 'Сведения о текущем сеансе'
$gui_infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$gui_infoGroup.AutoSize = $true
$gui_infoGroup.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$gui_infoLayout = New-Object System.Windows.Forms.TableLayoutPanel
$gui_infoLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$gui_infoLayout.AutoSize = $true
$gui_infoLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$gui_infoLayout.ColumnCount = 2
[void]$gui_infoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_infoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isAdministratorText = if (Test-IsAdministrator) { 'Да' } else { 'Нет' }
$infoRows = @(
    @('Имя компьютера:', $env:COMPUTERNAME),
    @('Учетная запись Windows:', $currentIdentity),
    @('Запуск от имени администратора:', $isAdministratorText)
)
foreach ($infoRow in $infoRows) {
    $gui_caption = New-Object System.Windows.Forms.Label
    $gui_caption.Text = $infoRow[0]
    $gui_caption.AutoSize = $true
    $gui_caption.Margin = New-Object System.Windows.Forms.Padding(8, 5, 6, 5)
    $gui_value = New-Object System.Windows.Forms.TextBox
    $gui_value.Text = $infoRow[1]
    $gui_value.ReadOnly = $true
    $gui_value.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gui_value.MinimumSize = New-Object Drawing.Size(0, 23)
    $gui_value.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 5)
    $gui_infoLayout.Controls.Add($gui_caption)
    $gui_infoLayout.Controls.Add($gui_value)
}
$gui_infoGroup.Controls.Add($gui_infoLayout)
$gui_rootLayout.Controls.Add($gui_infoGroup, 0, 0)

$gui_folderPanel = New-Object System.Windows.Forms.TableLayoutPanel
$gui_folderPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$gui_folderPanel.AutoSize = $true
$gui_folderPanel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$gui_folderPanel.ColumnCount = 4
[void]$gui_folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$gui_folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$gui_folderLabel = New-Object System.Windows.Forms.Label
$gui_folderLabel.Text = 'Папка с учетными данными:'
$gui_folderLabel.AutoSize = $true
$gui_folderLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$gui_folderPathTextBox = New-Object System.Windows.Forms.TextBox
$gui_folderPathTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$gui_folderPathTextBox.Text = $script:currentFolder
$gui_applyFolderButton = New-Object System.Windows.Forms.Button
$gui_applyFolderButton.Text = 'Применить'
$gui_applyFolderButton.AutoSize = $true
$gui_chooseFolderButton = New-Object System.Windows.Forms.Button
$gui_chooseFolderButton.Text = 'Выбрать папку...'
$gui_chooseFolderButton.AutoSize = $true
$gui_folderPanel.Controls.Add($gui_folderLabel, 0, 0)
$gui_folderPanel.Controls.Add($gui_folderPathTextBox, 1, 0)
$gui_folderPanel.Controls.Add($gui_applyFolderButton, 2, 0)
$gui_folderPanel.Controls.Add($gui_chooseFolderButton, 3, 0)
$gui_rootLayout.Controls.Add($gui_folderPanel, 0, 1)

$gui_buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$gui_buttonsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$gui_buttonsPanel.AutoSize = $true
$gui_buttonsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$gui_createCredentialButton = New-Object System.Windows.Forms.Button
$gui_createCredentialButton.Text = 'Создать файл с учетными данными'
$gui_createCredentialButton.AutoSize = $true
$script:gui_copyPasswordButton = New-Object System.Windows.Forms.Button
$script:gui_copyPasswordButton.Text = 'Скопировать пароль'
$script:gui_copyPasswordButton.AutoSize = $true
$script:gui_copyPasswordButton.Enabled = $false
$script:gui_changePasswordButton = New-Object System.Windows.Forms.Button
$script:gui_changePasswordButton.Text = 'Изменить пароль'
$script:gui_changePasswordButton.AutoSize = $true
$script:gui_changePasswordButton.Enabled = $false
$script:gui_deleteFileButton = New-Object System.Windows.Forms.Button
$script:gui_deleteFileButton.Text = 'Удалить выбранный файл'
$script:gui_deleteFileButton.AutoSize = $true
$script:gui_deleteFileButton.Enabled = $false
$gui_buttonsPanel.Controls.Add($gui_createCredentialButton)
$gui_buttonsPanel.Controls.Add($script:gui_copyPasswordButton)
$gui_buttonsPanel.Controls.Add($script:gui_changePasswordButton)
$gui_buttonsPanel.Controls.Add($script:gui_deleteFileButton)
$gui_rootLayout.Controls.Add($gui_buttonsPanel, 0, 2)

$gui_filesGroup = New-Object System.Windows.Forms.GroupBox
$gui_filesGroup.Text = 'Файлы XML'
$gui_filesGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:gui_credentialsList = New-Object System.Windows.Forms.ListView
$script:gui_credentialsList.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:gui_credentialsList.View = [System.Windows.Forms.View]::Details
$script:gui_credentialsList.FullRowSelect = $true
$script:gui_credentialsList.HideSelection = $false
$script:gui_credentialsList.MultiSelect = $false
$script:gui_credentialsList.ShowItemToolTips = $true
[void]$script:gui_credentialsList.Columns.Add('Имя файла', 590)
[void]$script:gui_credentialsList.Columns.Add('Состояние', 150)
$gui_filesGroup.Controls.Add($script:gui_credentialsList)
$gui_rootLayout.Controls.Add($gui_filesGroup, 0, 3)

$gui_detailsGroup = New-Object System.Windows.Forms.GroupBox
$gui_detailsGroup.Text = 'Выбранные учетные данные (пароль не отображается)'
$gui_detailsGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$gui_detailsGroup.AutoSize = $true
$gui_detailsGroup.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$gui_detailsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$gui_detailsLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$gui_detailsLayout.AutoSize = $true
$gui_detailsLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$gui_detailsLayout.ColumnCount = 2
[void]$gui_detailsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$gui_detailsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($property in @(
    @{ Caption = 'Домен:'; Variable = 'domainValue' },
    @{ Caption = 'Логин:'; Variable = 'loginValue' },
    @{ Caption = 'Файл:'; Variable = 'fileValue' }
)) {
    $gui_caption = New-Object System.Windows.Forms.Label
    $gui_caption.Text = $property.Caption
    $gui_caption.AutoSize = $true
    $gui_caption.Margin = New-Object System.Windows.Forms.Padding(8, 4, 6, 4)
    $gui_value = New-Object System.Windows.Forms.TextBox
    $gui_value.Text = '-'
    $gui_value.ReadOnly = $true
    $gui_value.Dock = [System.Windows.Forms.DockStyle]::Fill
    $gui_value.MinimumSize = New-Object Drawing.Size(0, 23)
    $gui_value.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    switch ($property.Variable) {
        'domainValue' { $script:gui_domainValue = $gui_value }
        'loginValue'  { $script:gui_loginValue = $gui_value }
        'fileValue'   { $script:gui_fileValue = $gui_value }
    }
    $gui_detailsLayout.Controls.Add($gui_caption)
    $gui_detailsLayout.Controls.Add($gui_value)
}
$gui_detailsGroup.Controls.Add($gui_detailsLayout)
$gui_rootLayout.Controls.Add($gui_detailsGroup, 0, 4)

$gui_logGroup = New-Object System.Windows.Forms.GroupBox
$gui_logGroup.Text = 'Журнал действий'
$gui_logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:gui_logTextBox = New-Object System.Windows.Forms.TextBox
$script:gui_logTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:gui_logTextBox.Multiline = $true
$script:gui_logTextBox.ReadOnly = $true
$script:gui_logTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:gui_logTextBox.Font = New-Object Drawing.Font('Consolas', 8)
$script:gui_logTextBox.Text = $startMessage + [Environment]::NewLine
$gui_logGroup.Controls.Add($script:gui_logTextBox)
$gui_rootLayout.Controls.Add($gui_logGroup, 0, 5)

function Apply-CredentialsFolder {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $candidatePath = [Environment]::ExpandEnvironmentVariables($FolderPath.Trim().Trim('"'))
    if ([String]::IsNullOrWhiteSpace($candidatePath)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Введите путь к существующей папке.',
            'Путь не указан',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Папка не существует или недоступна:`r`n$candidatePath",
            'Некорректный путь',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return $false
    }

    try {
        $script:currentFolder = (Resolve-Path -LiteralPath $candidatePath -ErrorAction Stop).Path
        $gui_folderPathTextBox.Text = $script:currentFolder
        Save-Settings
        Write-Log "Использована папка с учетными данными: $script:currentFolder"
        Load-CredentialFiles
        return $true
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось применить папку:`r`n$($_.Exception.Message)",
            'Ошибка папки',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return $false
    }
}

$gui_chooseFolderButton.Add_Click({
    $gui_folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $gui_folderDialog.Description = 'Выберите папку для хранения файлов учетных данных'
    $gui_folderDialog.SelectedPath = $script:currentFolder
    if ($gui_folderDialog.ShowDialog($gui_form) -eq [System.Windows.Forms.DialogResult]::OK) {
        [void](Apply-CredentialsFolder -FolderPath $gui_folderDialog.SelectedPath)
    }
    $gui_folderDialog.Dispose()
})

$gui_applyFolderButton.Add_Click({
    [void](Apply-CredentialsFolder -FolderPath $gui_folderPathTextBox.Text)
})

$gui_folderPathTextBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        [void](Apply-CredentialsFolder -FolderPath $gui_folderPathTextBox.Text)
    }
})

$script:gui_credentialsList.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::C -and $script:gui_credentialsList.SelectedItems.Count -gt 0) {
        $_.SuppressKeyPress = $true
        $gui_selectedListItem = $script:gui_credentialsList.SelectedItems[0]
        $rowText = "$($gui_selectedListItem.Text)`t$($gui_selectedListItem.SubItems[1].Text)"
        try {
            [System.Windows.Forms.Clipboard]::SetText($rowText)
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Не удалось скопировать строку:`r`n$($_.Exception.Message)",
                'Ошибка буфера обмена',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    }
})

$script:gui_credentialsList.Add_SelectedIndexChanged({
    if ($script:gui_credentialsList.SelectedItems.Count -eq 0) {
        Clear-CredentialDetails
        return
    }
    $data = $script:gui_credentialsList.SelectedItems[0].Tag
    Show-CredentialDetails -ItemData $data
    $script:gui_deleteFileButton.Enabled = $true
    Write-Log "Выбран для просмотра файл: $($data.Path)"
})

$gui_createCredentialButton.Add_Click({
    # Параметр -Title появился только в более новых версиях PowerShell.
    # -Message поддерживается Windows PowerShell 5.1.
    $credential = Get-Credential -Message 'Введите учетную запись в формате ДОМЕН\логин или логин@домен.'
    if ($null -eq $credential) {
        return
    }

    $parts = Get-CredentialParts -Credential $credential
    if ([String]::IsNullOrWhiteSpace($parts.Domain) -or [String]::IsNullOrWhiteSpace($parts.Login)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Не удалось определить домен и логин. Введите имя пользователя в формате ДОМЕН\логин или логин@домен.',
            'Нужны домен и логин',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $safeComputer = ConvertTo-SafeFileNamePart $env:COMPUTERNAME
    $safeDomain = ConvertTo-SafeFileNamePart $parts.Domain
    $safeLogin = ConvertTo-SafeFileNamePart $parts.Login
    $fileName = '{0}_{1}_{2}.xml' -f $safeComputer, $safeDomain, $safeLogin
    $filePath = Join-Path -Path $script:currentFolder -ChildPath $fileName

    if (Test-Path -LiteralPath $filePath -PathType Leaf) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Файл '$fileName' уже существует. Перезаписать его?",
            'Подтверждение перезаписи',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }
    }

    try {
        Export-Clixml -InputObject $credential -LiteralPath $filePath -Force -ErrorAction Stop
        Write-Log "Создан файл с учетными данными: $filePath"
        Load-CredentialFiles
        foreach ($gui_item in $script:gui_credentialsList.Items) {
            if ($gui_item.Tag.Path -eq $filePath) {
                $gui_item.Selected = $true
                $gui_item.Focused = $true
                $gui_item.EnsureVisible()
                break
            }
        }
    }
    catch {
        Write-Log "Не удалось создать файл '$filePath': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось сохранить учетные данные:`r`n$($_.Exception.Message)",
            'Ошибка сохранения',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$script:gui_copyPasswordButton.Add_Click({
    if ($script:gui_credentialsList.SelectedItems.Count -eq 0) {
        return
    }
    $data = $script:gui_credentialsList.SelectedItems[0].Tag
    if (-not $data.Readable) {
        return
    }

    try {
        Set-Clipboard -Value $data.Credential.GetNetworkCredential().Password -ErrorAction Stop
        Write-Log "Пароль скопирован в буфер обмена из файла: $($data.Path)"
        [System.Windows.Forms.MessageBox]::Show(
            'Пароль скопирован в буфер обмена.',
            'Готово',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Write-Log "Не удалось скопировать пароль из файла '$($data.Path)': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось скопировать пароль:`r`n$($_.Exception.Message)",
            'Ошибка буфера обмена',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

$script:gui_changePasswordButton.Add_Click({
    if ($script:gui_credentialsList.SelectedItems.Count -eq 0) {
        return
    }
    $data = $script:gui_credentialsList.SelectedItems[0].Tag
    if (-not $data.Readable) {
        return
    }

    $newPassword = Get-ConfirmedNewPassword -FileName $data.Name
    if ($null -eq $newPassword) {
        return
    }

    try {
        $updatedCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList @(
            $data.Credential.UserName,
            $newPassword
        )
        Export-Clixml -InputObject $updatedCredential -LiteralPath $data.Path -Force -ErrorAction Stop
        Write-Log "Изменен пароль в файле с учетными данными: $($data.Path)"
        Load-CredentialFiles
        foreach ($gui_item in $script:gui_credentialsList.Items) {
            if ($gui_item.Tag.Path -eq $data.Path) {
                $gui_item.Selected = $true
                $gui_item.Focused = $true
                $gui_item.EnsureVisible()
                break
            }
        }
        [System.Windows.Forms.MessageBox]::Show(
            'Пароль успешно изменен.',
            'Готово',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    }
    catch {
        Write-Log "Не удалось изменить пароль в файле '$($data.Path)': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось изменить пароль:`r`n$($_.Exception.Message)",
            'Ошибка изменения пароля',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
    finally {
        $updatedCredential = $null
        if ($null -ne $newPassword) {
            $newPassword.Dispose()
        }
    }
})

$script:gui_deleteFileButton.Add_Click({
    if ($script:gui_credentialsList.SelectedItems.Count -eq 0) {
        return
    }

    $data = $script:gui_credentialsList.SelectedItems[0].Tag
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Удалить файл учетных данных?`r`n`r`n$($data.Path)",
        'Подтверждение удаления',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    )
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Remove-Item -LiteralPath $data.Path -Force -ErrorAction Stop
        Write-Log "Удален файл с учетными данными: $($data.Path)"
        Load-CredentialFiles
    }
    catch {
        Write-Log "Не удалось удалить файл '$($data.Path)': $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось удалить файл:`r`n$($_.Exception.Message)",
            'Ошибка удаления',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

Write-Log "Использована папка с учетными данными: $script:currentFolder"
Load-CredentialFiles
[void]$gui_form.ShowDialog()
$gui_form.Dispose()
