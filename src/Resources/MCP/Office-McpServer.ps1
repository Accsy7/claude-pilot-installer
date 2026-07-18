param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Word', 'Excel')]
    [string]$Mode,

    [string]$AllowedRoot = 'D:\ClaudeDesktop\Cowork'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$script:OwnedUnsavedWordObjects = New-Object 'System.Collections.Generic.HashSet[long]'
$script:OwnedUnsavedExcelObjects = New-Object 'System.Collections.Generic.HashSet[long]'

function Write-McpMessage {
    param([Parameter(Mandatory = $true)]$Message)

    $json = $Message | ConvertTo-Json -Depth 30 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function New-TextResult {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [bool]$IsError = $false
    )

    if ($Value -is [string]) {
        $text = $Value
    }
    else {
        $text = $Value | ConvertTo-Json -Depth 20 -Compress
    }

    return @{
        content = @(@{ type = 'text'; text = $text })
        isError = $IsError
    }
}

function Get-ArgumentValue {
    param(
        $Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Arguments) {
        return $Default
    }

    $property = $Arguments.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}

function Get-ActiveComObject {
    param([Parameter(Mandatory = $true)][string]$ProgId)

    try {
        return [Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
    }
    catch {
        return $null
    }
}

function Release-ComObject {
    param($Object)

    if ($null -ne $Object -and [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        try {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($Object)
        }
        catch {
            # Releasing our local COM reference must never fail the tool call.
        }
    }
}

function Get-ComIdentity {
    param([Parameter(Mandatory = $true)]$Object)

    if (-not [Runtime.InteropServices.Marshal]::IsComObject($Object)) {
        throw 'Expected a Microsoft Office COM object.'
    }
    $unknown = [Runtime.InteropServices.Marshal]::GetIUnknownForObject($Object)
    try {
        return [long]$unknown.ToInt64()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::Release($unknown)
    }
}

function Resolve-OfficePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$MustExist = $false,
        [Parameter(Mandatory = $true)][string[]]$AllowedExtensions
    )

    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\')
    if ([IO.Path]::IsPathRooted($Path)) {
        $fullPath = [IO.Path]::GetFullPath($Path)
    }
    else {
        $fullPath = [IO.Path]::GetFullPath((Join-Path $root $Path))
    }

    $rootPrefix = $root + '\'
    if (-not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The path must stay inside the approved workspace: $root"
    }

    $extension = [IO.Path]::GetExtension($fullPath).ToLowerInvariant()
    if ($AllowedExtensions -notcontains $extension) {
        throw "Unsupported file type '$extension'. Allowed: $($AllowedExtensions -join ', ')"
    }

    if ($MustExist -and -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "File not found: $fullPath"
    }

    if (-not $MustExist) {
        $parent = Split-Path -Parent $fullPath
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Destination folder not found: $parent"
        }
    }

    $physicalCheckPath = if ($MustExist) { $fullPath } else { Split-Path -Parent $fullPath }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "The approved workspace must be a physical directory, not a reparse point: $root"
    }
    $relative = $physicalCheckPath.Substring($root.Length).TrimStart('\')
    $current = $root
    foreach ($component in @($relative.Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $_ })) {
        $current = Join-Path $current $component
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not allowed inside the approved workspace path: $current"
        }
    }
    if (-not $MustExist -and (Test-Path -LiteralPath $fullPath)) {
        $destinationItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to overwrite a reparse-point destination: $fullPath"
        }
    }

    return $fullPath
}

function Test-ActiveWordDocumentAllowed {
    param($Document)

    try {
        $documentPath = [string]$Document.Path
        if ([string]::IsNullOrWhiteSpace($documentPath)) {
            return $script:OwnedUnsavedWordObjects.Contains((Get-ComIdentity $Document))
        }
        [void](Resolve-OfficePath -Path ([string]$Document.FullName) -MustExist $true -AllowedExtensions @('.docx', '.doc', '.rtf', '.txt'))
        return $true
    }
    catch {
        return $false
    }
}

function Assert-ActiveWordDocumentAllowed {
    param($Document)

    if (-not (Test-ActiveWordDocumentAllowed $Document)) {
        throw 'The active Word document is outside the approved Cowork workspace, is behind a reparse point, or was not created by this MCP session.'
    }
}

function Test-ActiveExcelWorkbookAllowed {
    param($Workbook)

    try {
        $workbookPath = [string]$Workbook.Path
        if ([string]::IsNullOrWhiteSpace($workbookPath)) {
            return $script:OwnedUnsavedExcelObjects.Contains((Get-ComIdentity $Workbook))
        }
        [void](Resolve-OfficePath -Path ([string]$Workbook.FullName) -MustExist $true -AllowedExtensions @('.xlsx', '.xlsm', '.xls', '.csv'))
        return $true
    }
    catch {
        return $false
    }
}

function Assert-ActiveExcelWorkbookAllowed {
    param($Workbook)

    if (-not (Test-ActiveExcelWorkbookAllowed $Workbook)) {
        throw 'The active Excel workbook is outside the approved Cowork workspace, is behind a reparse point, or was not created by this MCP session.'
    }
}

function Get-WordApplication {
    param([bool]$CreateIfMissing = $false)

    $app = Get-ActiveComObject -ProgId 'Word.Application'
    if ($null -eq $app -and $CreateIfMissing) {
        $app = New-Object -ComObject Word.Application
        $app.Visible = $true
    }
    if ($null -eq $app) {
        throw 'Microsoft Word is not running. Open Word first or ask to create/open a document.'
    }
    return $app
}

function Get-ExcelApplication {
    param([bool]$CreateIfMissing = $false)

    $app = Get-ActiveComObject -ProgId 'Excel.Application'
    if ($null -eq $app -and $CreateIfMissing) {
        $app = New-Object -ComObject Excel.Application
        $app.Visible = $true
    }
    if ($null -eq $app) {
        throw 'Microsoft Excel is not running. Open Excel first or ask to create/open a workbook.'
    }
    return $app
}

function Get-ActiveWordDocument {
    param($Application)

    if ($Application.Documents.Count -lt 1) {
        throw 'Word is running, but no document is open.'
    }
    return $Application.ActiveDocument
}

function Get-ActiveExcelWorkbook {
    param($Application)

    if ($Application.Workbooks.Count -lt 1) {
        throw 'Excel is running, but no workbook is open.'
    }
    return $Application.ActiveWorkbook
}

function Invoke-WordTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Arguments
    )

    switch ($Name) {
        'word_status' {
            $app = Get-ActiveComObject -ProgId 'Word.Application'
            if ($null -eq $app) {
                return @{ running = $false; document_count = 0 }
            }
            try {
                $result = @{ running = $true; document_count = [int]$app.Documents.Count }
                if ($app.Documents.Count -gt 0) {
                    $document = $app.ActiveDocument
                    try {
                        $approved = Test-ActiveWordDocumentAllowed $document
                        $result.active_document_approved = $approved
                        if ($approved) {
                            $result.active_document = [string]$document.Name
                            $result.saved = [bool]$document.Saved
                        }
                    }
                    finally {
                        Release-ComObject $document
                    }
                }
                return $result
            }
            finally {
                Release-ComObject $app
            }
        }

        'word_create_document' {
            $initialText = [string](Get-ArgumentValue $Arguments 'initial_text' '')
            if ($initialText.Length -gt 100000) {
                throw 'initial_text exceeds the 100,000 character safety limit.'
            }
            $app = Get-WordApplication -CreateIfMissing $true
            $document = $null
            try {
                $document = $app.Documents.Add()
                $documentName = [string]$document.Name
                [void]$script:OwnedUnsavedWordObjects.Add((Get-ComIdentity $document))
                if ($initialText.Length -gt 0) {
                    $document.Content.Text = $initialText
                }
                $app.Visible = $true
                $app.Activate()
                return @{ created = $true; document = $documentName; saved = $false }
            }
            finally {
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        'word_open_document' {
            $path = [string](Get-ArgumentValue $Arguments 'path' '')
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required.'
            }
            $readOnly = [bool](Get-ArgumentValue $Arguments 'read_only' $true)
            $fullPath = Resolve-OfficePath -Path $path -MustExist $true -AllowedExtensions @('.docx', '.doc', '.rtf', '.txt')
            $app = Get-WordApplication -CreateIfMissing $true
            $document = $null
            try {
                $document = $app.Documents.Open($fullPath, $false, $readOnly)
                $app.Visible = $true
                $app.Activate()
                return @{ opened = $true; document = [string]$document.Name; read_only = $readOnly }
            }
            finally {
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        'word_read_document' {
            $maxChars = [int](Get-ArgumentValue $Arguments 'max_chars' 20000)
            if ($maxChars -lt 1 -or $maxChars -gt 100000) {
                throw 'max_chars must be between 1 and 100,000.'
            }
            $app = Get-WordApplication
            $document = $null
            $content = $null
            try {
                $document = Get-ActiveWordDocument $app
                Assert-ActiveWordDocumentAllowed $document
                $content = $document.Content
                $text = [string]$content.Text
                $truncated = $text.Length -gt $maxChars
                if ($truncated) {
                    $text = $text.Substring(0, $maxChars)
                }
                return @{
                    document = [string]$document.Name
                    text = $text
                    truncated = $truncated
                    total_characters = [int]$content.Text.Length
                }
            }
            finally {
                Release-ComObject $content
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        'word_append_text' {
            $text = [string](Get-ArgumentValue $Arguments 'text' '')
            if ([string]::IsNullOrEmpty($text)) {
                throw 'text is required.'
            }
            if ($text.Length -gt 100000) {
                throw 'text exceeds the 100,000 character safety limit.'
            }
            $app = Get-WordApplication
            $document = $null
            $range = $null
            try {
                $document = Get-ActiveWordDocument $app
                Assert-ActiveWordDocumentAllowed $document
                if ($document.ReadOnly) {
                    throw 'The active Word document is read-only.'
                }
                $end = [Math]::Max(0, [int]$document.Content.End - 1)
                $range = $document.Range($end, $end)
                $range.InsertAfter($text)
                return @{
                    changed = $true
                    document = [string]$document.Name
                    saved = $false
                    note = 'Text was appended in Word but was not saved to disk.'
                }
            }
            finally {
                Release-ComObject $range
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        'word_replace_text' {
            $search = [string](Get-ArgumentValue $Arguments 'search' '')
            $replacement = [string](Get-ArgumentValue $Arguments 'replacement' '')
            $replaceAll = [bool](Get-ArgumentValue $Arguments 'replace_all' $true)
            if ([string]::IsNullOrEmpty($search)) {
                throw 'search is required.'
            }
            $app = Get-WordApplication
            $document = $null
            $range = $null
            $find = $null
            try {
                $document = Get-ActiveWordDocument $app
                Assert-ActiveWordDocumentAllowed $document
                if ($document.ReadOnly) {
                    throw 'The active Word document is read-only.'
                }
                $range = $document.Content
                $find = $range.Find
                $replaceMode = 1
                if ($replaceAll) { $replaceMode = 2 }
                $changed = [bool]$find.Execute($search, $false, $false, $false, $false, $false, $true, 1, $false, $replacement, $replaceMode)
                return @{
                    changed = $changed
                    document = [string]$document.Name
                    saved = $false
                    note = 'Replacement was applied in Word but was not saved to disk.'
                }
            }
            finally {
                Release-ComObject $find
                Release-ComObject $range
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        'word_save_as' {
            $path = [string](Get-ArgumentValue $Arguments 'path' '')
            $overwrite = [bool](Get-ArgumentValue $Arguments 'overwrite' $false)
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required.'
            }
            $fullPath = Resolve-OfficePath -Path $path -AllowedExtensions @('.docx')
            if ((Test-Path -LiteralPath $fullPath) -and -not $overwrite) {
                throw 'Destination already exists. Choose a new filename or explicitly set overwrite=true.'
            }
            $app = Get-WordApplication
            $document = $null
            try {
                $document = Get-ActiveWordDocument $app
                Assert-ActiveWordDocumentAllowed $document
                $document.SaveAs2($fullPath, 16)
                [void]$script:OwnedUnsavedWordObjects.Remove((Get-ComIdentity $document))
                return @{ saved = $true; path = $fullPath; document = [string]$document.Name }
            }
            finally {
                Release-ComObject $document
                Release-ComObject $app
            }
        }

        default {
            throw "Unknown Word tool: $Name"
        }
    }
}

function Get-ExcelWorksheet {
    param(
        $Workbook,
        [string]$SheetName
    )

    if ([string]::IsNullOrWhiteSpace($SheetName)) {
        return $Workbook.ActiveSheet
    }
    return $Workbook.Worksheets.Item($SheetName)
}

function Invoke-ExcelTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Arguments
    )

    switch ($Name) {
        'excel_status' {
            $app = Get-ActiveComObject -ProgId 'Excel.Application'
            if ($null -eq $app) {
                return @{ running = $false; workbook_count = 0 }
            }
            try {
                $result = @{ running = $true; workbook_count = [int]$app.Workbooks.Count }
                if ($app.Workbooks.Count -gt 0) {
                    $workbook = $app.ActiveWorkbook
                    try {
                        $approved = Test-ActiveExcelWorkbookAllowed $workbook
                        $result.active_workbook_approved = $approved
                        if ($approved) {
                            $result.active_workbook = [string]$workbook.Name
                            $result.saved = [bool]$workbook.Saved
                        }
                    }
                    finally {
                        Release-ComObject $workbook
                    }
                }
                return $result
            }
            finally {
                Release-ComObject $app
            }
        }

        'excel_create_workbook' {
            $app = Get-ExcelApplication -CreateIfMissing $true
            $workbook = $null
            try {
                $workbook = $app.Workbooks.Add()
                $workbookName = [string]$workbook.Name
                [void]$script:OwnedUnsavedExcelObjects.Add((Get-ComIdentity $workbook))
                $app.Visible = $true
                $app.Activate()
                return @{ created = $true; workbook = $workbookName; saved = $false }
            }
            finally {
                Release-ComObject $workbook
                Release-ComObject $app
            }
        }

        'excel_open_workbook' {
            $path = [string](Get-ArgumentValue $Arguments 'path' '')
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required.'
            }
            $readOnly = [bool](Get-ArgumentValue $Arguments 'read_only' $true)
            $fullPath = Resolve-OfficePath -Path $path -MustExist $true -AllowedExtensions @('.xlsx', '.xlsm', '.xls', '.csv')
            $app = Get-ExcelApplication -CreateIfMissing $true
            $workbook = $null
            try {
                $workbook = $app.Workbooks.Open($fullPath, 0, $readOnly)
                $app.Visible = $true
                $app.Activate()
                return @{ opened = $true; workbook = [string]$workbook.Name; read_only = $readOnly }
            }
            finally {
                Release-ComObject $workbook
                Release-ComObject $app
            }
        }

        'excel_read_range' {
            $rangeAddress = [string](Get-ArgumentValue $Arguments 'range' '')
            $sheetName = [string](Get-ArgumentValue $Arguments 'sheet' '')
            if ([string]::IsNullOrWhiteSpace($rangeAddress)) {
                throw 'range is required, for example A1:C10.'
            }
            $app = Get-ExcelApplication
            $workbook = $null
            $worksheet = $null
            $range = $null
            try {
                $workbook = Get-ActiveExcelWorkbook $app
                Assert-ActiveExcelWorkbookAllowed $workbook
                $worksheet = Get-ExcelWorksheet $workbook $sheetName
                $range = $worksheet.Range($rangeAddress)
                $rowCount = [int]$range.Rows.Count
                $columnCount = [int]$range.Columns.Count
                if (($rowCount * $columnCount) -gt 2000) {
                    throw 'The requested range exceeds the 2,000-cell safety limit.'
                }
                $rows = New-Object System.Collections.ArrayList
                for ($row = 1; $row -le $rowCount; $row++) {
                    $cells = New-Object System.Collections.ArrayList
                    for ($column = 1; $column -le $columnCount; $column++) {
                        $cell = $range.Cells.Item($row, $column)
                        try {
                            [void]$cells.Add($cell.Value2)
                        }
                        finally {
                            Release-ComObject $cell
                        }
                    }
                    [void]$rows.Add($cells.ToArray())
                }
                return @{
                    workbook = [string]$workbook.Name
                    sheet = [string]$worksheet.Name
                    range = $rangeAddress
                    values = $rows.ToArray()
                    rows = $rowCount
                    columns = $columnCount
                }
            }
            finally {
                Release-ComObject $range
                Release-ComObject $worksheet
                Release-ComObject $workbook
                Release-ComObject $app
            }
        }

        'excel_write_range' {
            $startCell = [string](Get-ArgumentValue $Arguments 'start_cell' '')
            $sheetName = [string](Get-ArgumentValue $Arguments 'sheet' '')
            $values = Get-ArgumentValue $Arguments 'values' $null
            if ([string]::IsNullOrWhiteSpace($startCell)) {
                throw 'start_cell is required, for example A1.'
            }
            if ($null -eq $values) {
                throw 'values is required and must be a two-dimensional JSON array.'
            }
            $rows = @($values)
            if ($rows.Count -lt 1) {
                throw 'values cannot be empty.'
            }
            $firstRow = @($rows[0])
            $columnCount = $firstRow.Count
            if ($columnCount -lt 1) {
                throw 'values rows cannot be empty.'
            }
            if (($rows.Count * $columnCount) -gt 2000) {
                throw 'values exceeds the 2,000-cell safety limit.'
            }
            foreach ($rowValue in $rows) {
                if (@($rowValue).Count -ne $columnCount) {
                    throw 'All values rows must have the same number of columns.'
                }
            }

            $app = Get-ExcelApplication
            $workbook = $null
            $worksheet = $null
            $origin = $null
            try {
                $workbook = Get-ActiveExcelWorkbook $app
                Assert-ActiveExcelWorkbookAllowed $workbook
                if ($workbook.ReadOnly) {
                    throw 'The active Excel workbook is read-only.'
                }
                $worksheet = Get-ExcelWorksheet $workbook $sheetName
                $origin = $worksheet.Range($startCell)
                for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
                    $currentRow = @($rows[$rowIndex])
                    for ($columnIndex = 0; $columnIndex -lt $columnCount; $columnIndex++) {
                        $cell = $origin.Offset($rowIndex, $columnIndex)
                        try {
                            $value = $currentRow[$columnIndex]
                            if ($value -is [string] -and $value.StartsWith('=')) {
                                $cell.Formula = $value
                            }
                            else {
                                $cell.Value2 = $value
                            }
                        }
                        finally {
                            Release-ComObject $cell
                        }
                    }
                }
                return @{
                    changed = $true
                    workbook = [string]$workbook.Name
                    sheet = [string]$worksheet.Name
                    start_cell = $startCell
                    rows = $rows.Count
                    columns = $columnCount
                    saved = $false
                    note = 'Cells were changed in Excel but the workbook was not saved to disk.'
                }
            }
            finally {
                Release-ComObject $origin
                Release-ComObject $worksheet
                Release-ComObject $workbook
                Release-ComObject $app
            }
        }

        'excel_save_as' {
            $path = [string](Get-ArgumentValue $Arguments 'path' '')
            $overwrite = [bool](Get-ArgumentValue $Arguments 'overwrite' $false)
            if ([string]::IsNullOrWhiteSpace($path)) {
                throw 'path is required.'
            }
            $fullPath = Resolve-OfficePath -Path $path -AllowedExtensions @('.xlsx')
            if ((Test-Path -LiteralPath $fullPath) -and -not $overwrite) {
                throw 'Destination already exists. Choose a new filename or explicitly set overwrite=true.'
            }
            $app = Get-ExcelApplication
            $workbook = $null
            try {
                $workbook = Get-ActiveExcelWorkbook $app
                Assert-ActiveExcelWorkbookAllowed $workbook
                $previousAlerts = [bool]$app.DisplayAlerts
                try {
                    $app.DisplayAlerts = $false
                    $workbook.SaveAs($fullPath, 51)
                }
                finally {
                    $app.DisplayAlerts = $previousAlerts
                }
                [void]$script:OwnedUnsavedExcelObjects.Remove((Get-ComIdentity $workbook))
                return @{ saved = $true; path = $fullPath; workbook = [string]$workbook.Name }
            }
            finally {
                Release-ComObject $workbook
                Release-ComObject $app
            }
        }

        default {
            throw "Unknown Excel tool: $Name"
        }
    }
}

function New-ToolDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$Properties,
        [string[]]$Required = @()
    )

    $schema = @{
        type = 'object'
        properties = $Properties
        additionalProperties = $false
    }
    if ($Required.Count -gt 0) {
        $schema.required = $Required
    }

    return @{
        name = $Name
        description = $Description
        inputSchema = $schema
    }
}

function Get-WordTools {
    return @(
        (New-ToolDefinition 'word_status' 'Check whether Word is running and report the active document. This makes no changes.' @{}),
        (New-ToolDefinition 'word_create_document' 'Create a new visible, unsaved Word document. Nothing is saved to disk.' @{
            initial_text = @{ type = 'string'; description = 'Optional initial text, up to 100,000 characters.' }
        }),
        (New-ToolDefinition 'word_open_document' "Open a Word file inside $AllowedRoot. Files open read-only by default." @{
            path = @{ type = 'string'; description = 'Absolute path or a path relative to the approved workspace.' }
            read_only = @{ type = 'boolean'; default = $true; description = 'Keep true unless editing is explicitly required.' }
        } @('path')),
        (New-ToolDefinition 'word_read_document' 'Read text from the active Word document. This makes no changes.' @{
            max_chars = @{ type = 'integer'; minimum = 1; maximum = 100000; default = 20000 }
        }),
        (New-ToolDefinition 'word_append_text' 'Append text to the active editable Word document. The change remains unsaved until an explicit save action.' @{
            text = @{ type = 'string'; description = 'Text to append, up to 100,000 characters.' }
        } @('text')),
        (New-ToolDefinition 'word_replace_text' 'Replace text in the active editable Word document. The change remains unsaved until an explicit save action.' @{
            search = @{ type = 'string' }
            replacement = @{ type = 'string' }
            replace_all = @{ type = 'boolean'; default = $true }
        } @('search', 'replacement')),
        (New-ToolDefinition 'word_save_as' "Save the active Word document as a .docx inside $AllowedRoot. Existing files are protected unless overwrite=true is explicit." @{
            path = @{ type = 'string'; description = 'A .docx path inside the approved workspace.' }
            overwrite = @{ type = 'boolean'; default = $false }
        } @('path'))
    )
}

function Get-ExcelTools {
    return @(
        (New-ToolDefinition 'excel_status' 'Check whether Excel is running and report the active workbook. This makes no changes.' @{}),
        (New-ToolDefinition 'excel_create_workbook' 'Create a new visible, unsaved Excel workbook. Nothing is saved to disk.' @{}),
        (New-ToolDefinition 'excel_open_workbook' "Open an Excel file inside $AllowedRoot. Files open read-only by default." @{
            path = @{ type = 'string'; description = 'Absolute path or a path relative to the approved workspace.' }
            read_only = @{ type = 'boolean'; default = $true; description = 'Keep true unless editing is explicitly required.' }
        } @('path')),
        (New-ToolDefinition 'excel_read_range' 'Read up to 2,000 cells from the active Excel workbook. This makes no changes.' @{
            sheet = @{ type = 'string'; description = 'Optional worksheet name. The active sheet is used when omitted.' }
            range = @{ type = 'string'; description = 'Excel range such as A1:C10.' }
        } @('range')),
        (New-ToolDefinition 'excel_write_range' 'Write up to 2,000 cells to the active editable workbook. Formulas may begin with =. Changes remain unsaved until an explicit save action.' @{
            sheet = @{ type = 'string'; description = 'Optional worksheet name. The active sheet is used when omitted.' }
            start_cell = @{ type = 'string'; description = 'Top-left cell such as A1.' }
            values = @{
                type = 'array'
                description = 'A rectangular two-dimensional array of rows and cells.'
                items = @{ type = 'array'; items = @{} }
            }
        } @('start_cell', 'values')),
        (New-ToolDefinition 'excel_save_as' "Save the active workbook as .xlsx inside $AllowedRoot. Existing files are protected unless overwrite=true is explicit." @{
            path = @{ type = 'string'; description = 'An .xlsx path inside the approved workspace.' }
            overwrite = @{ type = 'boolean'; default = $false }
        } @('path'))
    )
}

if ($Mode -eq 'Word') {
    $toolDefinitions = Get-WordTools
    $serverName = 'company-word-local'
}
else {
    $toolDefinitions = Get-ExcelTools
    $serverName = 'company-excel-local'
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) {
        break
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        continue
    }

    try {
        $request = $line | ConvertFrom-Json
        $idProperty = $request.PSObject.Properties['id']
        $hasId = $null -ne $idProperty
        $method = [string]$request.method

        if (-not $hasId) {
            # MCP notifications do not receive a response.
            continue
        }

        switch ($method) {
            'initialize' {
                $requestedVersion = '2024-11-05'
                if ($null -ne $request.params -and
                    $null -ne $request.params.PSObject.Properties['protocolVersion'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$request.params.protocolVersion)) {
                    $requestedVersion = [string]$request.params.protocolVersion
                }
                Write-McpMessage @{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{
                        protocolVersion = $requestedVersion
                        capabilities = @{ tools = @{ listChanged = $false } }
                        serverInfo = @{ name = $serverName; version = '1.0.0' }
                    }
                }
            }

            'ping' {
                Write-McpMessage @{ jsonrpc = '2.0'; id = $request.id; result = @{} }
            }

            'tools/list' {
                Write-McpMessage @{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = @{ tools = $toolDefinitions }
                }
            }

            'tools/call' {
                $toolName = [string]$request.params.name
                $toolArguments = $request.params.arguments
                try {
                    if ($Mode -eq 'Word') {
                        $toolValue = Invoke-WordTool -Name $toolName -Arguments $toolArguments
                    }
                    else {
                        $toolValue = Invoke-ExcelTool -Name $toolName -Arguments $toolArguments
                    }
                    $toolResult = New-TextResult $toolValue
                }
                catch {
                    $toolResult = New-TextResult -Value $_.Exception.Message -IsError $true
                }
                Write-McpMessage @{
                    jsonrpc = '2.0'
                    id = $request.id
                    result = $toolResult
                }
            }

            default {
                Write-McpMessage @{
                    jsonrpc = '2.0'
                    id = $request.id
                    error = @{ code = -32601; message = "Method not found: $method" }
                }
            }
        }
    }
    catch {
        try {
            $errorId = $null
            if ($null -ne $request -and $null -ne $request.PSObject.Properties['id']) {
                $errorId = $request.id
            }
            Write-McpMessage @{
                jsonrpc = '2.0'
                id = $errorId
                error = @{ code = -32603; message = $_.Exception.Message }
            }
        }
        catch {
            # If stdout itself is unavailable, the stdio transport is already closed.
            break
        }
    }
}
