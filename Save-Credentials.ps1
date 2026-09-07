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
$script:credentialsList = $null
$script:logTextBox = $null
$script:domainValue = $null
$script:loginValue = $null
$script:fileValue = $null
$script:copyPasswordButton = $null
$script:deleteFileButton = $null
$script:copyFileButton = $null
$script:copyDetailsButton = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CredentialParts {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential
    )

    $userName = $Credential.UserName.Trim()
    $networkCredential = $Credential.GetNetworkCredential()
    $domain = ''
    $login = $networkCredential.UserName

    if ($userName -match '^(?<Domain>[^\\]+)\\(?<Login>.+)$') {
        $domain = $Matches.Domain
        $login = $Matches.Login
    }
    elseif ($userName -match '^(?<Login>[^@]+)@(?<Domain>.+)$') {
        $domain = $Matches.Domain
        $login = $Matches.Login
    }
    elseif (-not [String]::IsNullOrWhiteSpace($networkCredential.Domain)) {
        $domain = $networkCredential.Domain
    }

    return [pscustomobject]@{
        Domain = $domain
        Login  = $login
    }
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

    if ($null -ne $script:logTextBox -and -not $script:logTextBox.IsDisposed) {
        $script:logTextBox.AppendText($line + [Environment]::NewLine)
        $script:logTextBox.SelectionStart = $script:logTextBox.TextLength
        $script:logTextBox.ScrollToCaret()
    }
}

function Copy-InterfaceText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ItemName
    )

    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Не удалось скопировать ${ItemName}:`r`n$($_.Exception.Message)",
            'Ошибка буфера обмена',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
}

function Clear-CredentialDetails {
    $script:domainValue.Text = '-'
    $script:loginValue.Text = '-'
    $script:fileValue.Text = '-'
    $script:copyPasswordButton.Enabled = $false
    $script:deleteFileButton.Enabled = $false
    $script:copyFileButton.Enabled = $false
    $script:copyDetailsButton.Enabled = $false
}

function Show-CredentialDetails {
    param([Parameter(Mandatory = $true)]$ItemData)

    if (-not $ItemData.Readable) {
        Clear-CredentialDetails
        $script:fileValue.Text = "$($ItemData.Name) (недоступен для чтения)"
        return
    }

    $script:domainValue.Text = $ItemData.Domain
    $script:loginValue.Text = $ItemData.Login
    $script:fileValue.Text = $ItemData.Name
    $script:copyPasswordButton.Enabled = $true
    $script:copyDetailsButton.Enabled = $true
}

function Load-CredentialFiles {
    $script:credentialsList.BeginUpdate()
    try {
        $script:credentialsList.Items.Clear()
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
            }

            $item = New-Object System.Windows.Forms.ListViewItem($file.Name)
            [void]$item.SubItems.Add($(if ($readable) { 'Доступен' } else { 'Недоступен' }))
            $item.Tag = [pscustomobject]@{
                Name       = $file.Name
                Path       = $file.FullName
                Readable   = $readable
                Credential = $credential
                Domain     = if ($readable) { $parts.Domain } else { '' }
                Login      = if ($readable) { $parts.Login } else { '' }
                Error      = if ($readable) { '' } else { $readError }
            }
            if (-not $readable) {
                $item.ForeColor = [Drawing.Color]::Firebrick
                $item.ToolTipText = "Недоступен для чтения: $readError"
            }
            [void]$script:credentialsList.Items.Add($item)
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
        $script:credentialsList.EndUpdate()
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

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Сохранение учетных данных'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object Drawing.Size(940, 700)
$form.MinimumSize = New-Object Drawing.Size(780, 580)
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$rootLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 6
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 55)))
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 45)))
$form.Controls.Add($rootLayout)

$infoGroup = New-Object System.Windows.Forms.GroupBox
$infoGroup.Text = 'Сведения о текущем сеансе'
$infoGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$infoGroup.AutoSize = $true
$infoGroup.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$infoLayout = New-Object System.Windows.Forms.TableLayoutPanel
$infoLayout.Dock = [System.Windows.Forms.DockStyle]::Top
$infoLayout.AutoSize = $true
$infoLayout.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$infoLayout.ColumnCount = 2
$infoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$infoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$isAdministratorText = if (Test-IsAdministrator) { 'Да' } else { 'Нет' }
$infoRows = @(
    @('Имя компьютера:', $env:COMPUTERNAME),
    @('Учетная запись Windows:', $currentIdentity),
    @('Запуск от имени администратора:', $isAdministratorText)
)
foreach ($infoRow in $infoRows) {
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $infoRow[0]
    $caption.AutoSize = $true
    $caption.Margin = New-Object System.Windows.Forms.Padding(8, 5, 6, 5)
    $value = New-Object System.Windows.Forms.Label
    $value.Text = $infoRow[1]
    $value.AutoSize = $true
    $value.MaximumSize = New-Object Drawing.Size(650, 0)
    $value.Margin = New-Object System.Windows.Forms.Padding(0, 5, 8, 5)
    $infoLayout.Controls.Add($caption)
    $infoLayout.Controls.Add($value)
}
$copySessionInfoButton = New-Object System.Windows.Forms.Button
$copySessionInfoButton.Text = 'Копировать сведения'
$copySessionInfoButton.AutoSize = $true
$copySessionInfoButton.Anchor = [System.Windows.Forms.AnchorStyles]::Right
$infoLayout.Controls.Add($copySessionInfoButton, 1, $infoRows.Count)
$copySessionInfoButton.Add_Click({
    $sessionText = @(
        "Имя компьютера: $env:COMPUTERNAME",
        "Учетная запись Windows: $currentIdentity",
        "Запуск от имени администратора: $isAdministratorText"
    ) -join [Environment]::NewLine
    Copy-InterfaceText -Text $sessionText -ItemName 'сведения о текущем сеансе'
})
$infoGroup.Controls.Add($infoLayout)
$rootLayout.Controls.Add($infoGroup, 0, 0)

$folderPanel = New-Object System.Windows.Forms.TableLayoutPanel
$folderPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$folderPanel.AutoSize = $true
$folderPanel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
$folderPanel.ColumnCount = 4
$folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$folderLabel = New-Object System.Windows.Forms.Label
$folderLabel.Text = 'Папка с учетными данными:'
$folderLabel.AutoSize = $true
$folderLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$folderPathTextBox = New-Object System.Windows.Forms.TextBox
$folderPathTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$folderPathTextBox.Text = $script:currentFolder
$applyFolderButton = New-Object System.Windows.Forms.Button
$applyFolderButton.Text = 'Применить'
$applyFolderButton.AutoSize = $true
$chooseFolderButton = New-Object System.Windows.Forms.Button
$chooseFolderButton.Text = 'Выбрать папку...'
$chooseFolderButton.AutoSize = $true
$folderPanel.Controls.Add($folderLabel, 0, 0)
$folderPanel.Controls.Add($folderPathTextBox, 1, 0)
$folderPanel.Controls.Add($applyFolderButton, 2, 0)
$folderPanel.Controls.Add($chooseFolderButton, 3, 0)
$rootLayout.Controls.Add($folderPanel, 0, 1)

$buttonsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$buttonsPanel.AutoSize = $true
$buttonsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$createCredentialButton = New-Object System.Windows.Forms.Button
$createCredentialButton.Text = 'Создать файл с учетными данными'
$createCredentialButton.AutoSize = $true
$script:copyPasswordButton = New-Object System.Windows.Forms.Button
$script:copyPasswordButton.Text = 'Скопировать пароль'
$script:copyPasswordButton.AutoSize = $true
$script:copyPasswordButton.Enabled = $false
$script:deleteFileButton = New-Object System.Windows.Forms.Button
$script:deleteFileButton.Text = 'Удалить выбранный файл'
$script:deleteFileButton.AutoSize = $true
$script:deleteFileButton.Enabled = $false
$buttonsPanel.Controls.Add($createCredentialButton)
$buttonsPanel.Controls.Add($script:copyPasswordButton)
$buttonsPanel.Controls.Add($script:deleteFileButton)
$rootLayout.Controls.Add($buttonsPanel, 0, 2)

$filesGroup = New-Object System.Windows.Forms.GroupBox
$filesGroup.Text = 'Файлы XML'
$filesGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$filesLayout = New-Object System.Windows.Forms.TableLayoutPanel
$filesLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$filesLayout.ColumnCount = 1
$filesLayout.RowCount = 2
$filesLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$filesLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$filesActionsPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$filesActionsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$filesActionsPanel.AutoSize = $true
$filesActionsPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft
$script:copyFileButton = New-Object System.Windows.Forms.Button
$script:copyFileButton.Text = 'Копировать выбранный файл'
$script:copyFileButton.AutoSize = $true
$script:copyFileButton.Enabled = $false
$filesActionsPanel.Controls.Add($script:copyFileButton)
$script:credentialsList = New-Object System.Windows.Forms.ListView
$script:credentialsList.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:credentialsList.View = [System.Windows.Forms.View]::Details
$script:credentialsList.FullRowSelect = $true
$script:credentialsList.HideSelection = $false
$script:credentialsList.MultiSelect = $false
$script:credentialsList.ShowItemToolTips = $true
[void]$script:credentialsList.Columns.Add('Имя файла', 590)
[void]$script:credentialsList.Columns.Add('Состояние', 150)
$filesLayout.Controls.Add($filesActionsPanel, 0, 0)
$filesLayout.Controls.Add($script:credentialsList, 0, 1)
$filesGroup.Controls.Add($filesLayout)
$rootLayout.Controls.Add($filesGroup, 0, 3)

$detailsGroup = New-Object System.Windows.Forms.GroupBox
$detailsGroup.Text = 'Выбранные учетные данные (пароль не отображается)'
$detailsGroup.Dock = [System.Windows.Forms.DockStyle]::Top
$detailsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$detailsLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$detailsLayout.AutoSize = $true
$detailsLayout.ColumnCount = 2
$detailsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
$detailsLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
foreach ($property in @(
    @{ Caption = 'Домен:'; Variable = 'domainValue' },
    @{ Caption = 'Логин:'; Variable = 'loginValue' },
    @{ Caption = 'Файл:'; Variable = 'fileValue' }
)) {
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $property.Caption
    $caption.AutoSize = $true
    $caption.Margin = New-Object System.Windows.Forms.Padding(8, 4, 6, 4)
    $value = New-Object System.Windows.Forms.Label
    $value.Text = '-'
    $value.AutoSize = $true
    $value.AutoEllipsis = $true
    $value.Dock = [System.Windows.Forms.DockStyle]::Fill
    $value.Margin = New-Object System.Windows.Forms.Padding(0, 4, 8, 4)
    switch ($property.Variable) {
        'domainValue' { $script:domainValue = $value }
        'loginValue'  { $script:loginValue = $value }
        'fileValue'   { $script:fileValue = $value }
    }
    $detailsLayout.Controls.Add($caption)
    $detailsLayout.Controls.Add($value)
}
$script:copyDetailsButton = New-Object System.Windows.Forms.Button
$script:copyDetailsButton.Text = 'Копировать сведения'
$script:copyDetailsButton.AutoSize = $true
$script:copyDetailsButton.Anchor = [System.Windows.Forms.AnchorStyles]::Right
$script:copyDetailsButton.Enabled = $false
$detailsLayout.Controls.Add($script:copyDetailsButton, 1, 3)
$detailsGroup.Controls.Add($detailsLayout)
$rootLayout.Controls.Add($detailsGroup, 0, 4)

$logGroup = New-Object System.Windows.Forms.GroupBox
$logGroup.Text = 'Журнал действий'
$logGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:logTextBox = New-Object System.Windows.Forms.TextBox
$script:logTextBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:logTextBox.Multiline = $true
$script:logTextBox.ReadOnly = $true
$script:logTextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$script:logTextBox.Font = New-Object Drawing.Font('Consolas', 8)
$script:logTextBox.Text = $startMessage + [Environment]::NewLine
$logGroup.Controls.Add($script:logTextBox)
$rootLayout.Controls.Add($logGroup, 0, 5)

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
        $folderPathTextBox.Text = $script:currentFolder
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

$chooseFolderButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Выберите папку для хранения файлов учетных данных'
    $dialog.SelectedPath = $script:currentFolder
    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        [void](Apply-CredentialsFolder -FolderPath $dialog.SelectedPath)
    }
    $dialog.Dispose()
})

$applyFolderButton.Add_Click({
    [void](Apply-CredentialsFolder -FolderPath $folderPathTextBox.Text)
})

$folderPathTextBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        [void](Apply-CredentialsFolder -FolderPath $folderPathTextBox.Text)
    }
})

$script:copyFileButton.Add_Click({
    if ($script:credentialsList.SelectedItems.Count -eq 0) {
        return
    }

    $selectedItem = $script:credentialsList.SelectedItems[0]
    $fileText = @(
        "Имя файла: $($selectedItem.Text)",
        "Состояние: $($selectedItem.SubItems[1].Text)"
    ) -join [Environment]::NewLine
    Copy-InterfaceText -Text $fileText -ItemName 'данные выбранного XML-файла'
})

$script:credentialsList.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::C -and $script:copyFileButton.Enabled) {
        $_.SuppressKeyPress = $true
        $script:copyFileButton.PerformClick()
    }
})

$script:copyDetailsButton.Add_Click({
    if ($script:credentialsList.SelectedItems.Count -eq 0 -or -not $script:copyDetailsButton.Enabled) {
        return
    }

    $detailsText = @(
        "Домен: $($script:domainValue.Text)",
        "Логин: $($script:loginValue.Text)",
        "Файл: $($script:fileValue.Text)"
    ) -join [Environment]::NewLine
    Copy-InterfaceText -Text $detailsText -ItemName 'выбранные учетные данные'
})

$script:credentialsList.Add_SelectedIndexChanged({
    if ($script:credentialsList.SelectedItems.Count -eq 0) {
        Clear-CredentialDetails
        return
    }
    $data = $script:credentialsList.SelectedItems[0].Tag
    Show-CredentialDetails -ItemData $data
    $script:deleteFileButton.Enabled = $true
    $script:copyFileButton.Enabled = $true
    Write-Log "Выбран для просмотра файл: $($data.Path)"
})

$createCredentialButton.Add_Click({
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
        foreach ($item in $script:credentialsList.Items) {
            if ($item.Tag.Path -eq $filePath) {
                $item.Selected = $true
                $item.Focused = $true
                $item.EnsureVisible()
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

$script:copyPasswordButton.Add_Click({
    if ($script:credentialsList.SelectedItems.Count -eq 0) {
        return
    }
    $data = $script:credentialsList.SelectedItems[0].Tag
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

$script:deleteFileButton.Add_Click({
    if ($script:credentialsList.SelectedItems.Count -eq 0) {
        return
    }

    $data = $script:credentialsList.SelectedItems[0].Tag
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
[void]$form.ShowDialog()
$form.Dispose()
