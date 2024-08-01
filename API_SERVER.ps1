using namespace System.IO

# Vars definition - Prevents them from being shared/overridden with internal scripts being executed.
$Private:BaseCodeLineCount = $null
$Private:CompleteScript = $null
$Private:Entry = $null
$Private:EnvVars = $null
$Private:IsPowerShellNative = $null
$Private:ParsedEntry = $null
$Private:StartupVars = $null
$Private:UserVars = $null
$Private:FinalScript = $null
$Private:ScriptName = $null
$Private:ScriptPath = $null
$Private:ScriptExists = $null
$Private:StackTrace = $null
$Private:ExceptionBody = $null
$Private:Regex1 = $null
$Private:Regex2 = $null
$Private:Matches1 = $null
$Private:Matches2 = $null
$Private:Object = $null
$Private:FinalLineNumber = $null
$Private:ExceptionMessage = $null
$Private:LooperFileName = $null
# Save all env variables for later restoration after internal script execution
$EnvVars = Get-ChildItem env:

# Setup IO Streams
$OutputStream = [Console]::Out
$InputStream = [Console]::In

$Private:StdoutDupReader = $null
$Private:StderrDupReader = $null
# We dup the stdout(1),stderr(2) file descriptors (linux only)
# this ensures that native code that writes directly to stdout/stderr is caught to a file
if ($IsLinux -and $Env:_PWSH_DUP_STD_FDS -ne "no")
{
    $signature = @'
[DllImport ("libc", SetLastError=true)]
public static extern int dup (int fileDescriptor);
[DllImport ("libc", SetLastError=true)]
public static extern int dup2 (int oldFileDescriptor, int newFileDescriptor);
'@;
    Add-Type -MemberDefinition $signature -Name LibC -Namespace PInvoke -Using PInvoke

    function Private:DupFdToFile ([Int32]$fd)
    {
        <#
        .Description
        Dup2 the passed file descriptor to point to a new file. Return a Stream of the file
        which can be used for reading.
        #>
        $tmpfile = New-TemporaryFile
        $fd_new = [FileStream]::New($tmpfile.FullName, [FileMode]::Truncate, [FileAccess]::ReadWrite, [FileShare]::ReadWrite)
        # override the file descriptor with this file
        [PInvoke.LibC]::dup2($fd_new.Handle, $fd) | Out-Null
        return $tmpfile.OpenText()

    }

    $Private:stdout_copy_fd = [Microsoft.Win32.SafeHandles.SafeFileHandle]::New([PInvoke.LibC]::dup(1), $true)
    $OutputStream = [StreamWriter]::New([FileStream]::New($stdout_copy_fd, [FileAccess]::Write))
    $OutputStream.AutoFlush = $true
    # redirect stdout and stderr to files
    $StdoutDupReader = DupFdToFile 1
    $StderrDupReader = DupFdToFile 2
}

# Powershell duplicates the stdout/stderr FDs (probably as a result of threading)
# On linux run: pwsh -Command ls -l  '/proc/$PID/fd' to see how /dev/pts/0 is used
# by multiple file descriptors and not just 0,1,2
# To deal with this we point the console out/err to a string writer
$Private:ConsoleOutWriter = [System.IO.StringWriter]::New()
$Private:ConsoleErrWriter = [System.IO.StringWriter]::New()
[Console]::SetOut($ConsoleOutWriter)
[Console]::SetError($ConsoleErrWriter)


function ServerRequest ([hashtable]$Cmd)
{
    <#
    .Description
    Used to communicate with server in real time, mainly for logging and ExecuteCommand
    #>
    $Command = $Cmd | ConvertTo-Json -Compress -Depth 20
    $OutputStream.WriteLine($Command)
    $ServerResponse = $InputStream.ReadLine()

    $ServerErrorMarker = '[ERROR-fd5a7750-7182-4b38-90ba-091824478903]'
    $ErrorIndex = $ServerResponse.IndexOf($ServerErrorMarker)
    if ($ServerResponse -and $ErrorIndex -ne -1)
    {
        throw $ServerResponse.Substring($ErrorIndex + $ServerErrorMarker.Length)
    }

    return $ServerResponse | ConvertFrom-Json -AsHashtable
}

enum ServerLogLevel
{
    debug
    info
    error
}

enum BasicEntryTypes
{
    note = 1
    error = 4
    warning = 11
}

function ServerLog([string]$level)
{
    <#
    .Description
    Server log. level should be one of: ServerLogLevel. Param definition is intentionally a string for flexability.
    Additional args are loged.
    For example ServerLog "error" "this is a test log"
    #>
    return ServerRequest @{type = "log"; command = $level; args = @{args = $args } }
}

function TextEntry([int]$entryType, [string]$message)
{
    <#
    .Description
    Send a simple text entry to the server. Return null
    #>
    $entry = @{Type = $entryType; ContentsFormat = "text"; Contents = $message }
    $Cmd = @{type = "result"; results = @($entry) }
    $Command = $Cmd | ConvertTo-Json -Compress -Depth 20
    $OutputStream.WriteLine($Command)
    return $null
}

function Private:SendStdTextTo([string]$target, [string]$defaultTarget, [string]$message)
{
    <#
    .Description
    Send text to the server. Target maybe one of the following:
    note, warning, error, log_info, log_error, log_debug, none
    #>
    $doEntry = $false
    $entryType = [BasicEntryTypes]::warning
    $logLevel = [ServerLogLevel]::info
    if (-not $target )
    {
        # no need to check target as it is empty
        $target = $defaultTarget
    }
    switch ($target, $defaultTarget)
    {
        "none"
        {
            return $null
        }
        "note"
        {
            $doEntry = $true
            $entryType = [BasicEntryTypes]::note
            Break
        }
        "warning"
        {
            $doEntry = $true
            $entryType = [BasicEntryTypes]::warning
            Break
        }
        "error"
        {
            $doEntry = $true
            $entryType = [BasicEntryTypes]::error
            Break
        }
        "log_info"
        {
            $logLevel = [ServerLogLevel]::info
            Break
        }
        "log_error"
        {
            $logLevel = [ServerLogLevel]::error
            Break
        }
        "log_debug"
        {
            $logLevel = [ServerLogLevel]::debug
            Break
        }
        default
        {
            # if here means that $target is unknown. Append to message
            $message += "`nWarning: Powershell loop received unknown _PWSH_STD* value: $_"
        }
    }
    if ($doEntry)
    {
        TextEntry $entryType $message | Out-Null
    }
    else
    {
        ServerLog $logLevel $message | Out-Null
    }
    return $null
}

function Private:Get-Entry
{
    <#
    .Description
    Wait for ping from server, send pong, get server's entry and return to main loop
    #>
    $Pong = @{ type = 'pong' } | ConvertTo-Json -Compress
    while ($true)
    {
        # Read STDIN
        $Entry = $InputStream.ReadLine()
        if ($null -eq $Entry)
        {
            throw "End of stream reached when doing Get-Entry InputStream.ReadLine()"
        }
        if ($Entry -eq 'ping')
        {
            $OutputStream.WriteLine($Pong)
        }
        else
        {
            return $Entry
        }
    }
}

while ($true)
{
    $Entry = Get-Entry
    $ParsedEntry = ConvertFrom-Json -AsHashTable –InputObject $Entry
    # Get the script part of the entry from server and remove it so it won't be available in context on execute.
    $CompleteScript = $ParsedEntry.script
    $ParsedEntry.PSObject.Properties.Remove('script') | Out-Null
    $global:InnerContext = $ParsedEntry  # CommonServer script will use this to create the  object
    # Calculate length of lines of entire code being executed except for the user script part
    $BaseCodeLineCount = $ParsedEntry.linecount
    # Set up script name and paths
    $ScriptName = 'pwshcodescript.ps1'
    $ScriptPath = './'
    $ScriptExists = [System.IO.File]::Exists($ScriptPath + $ScriptName)
    # In case the script already exists assume docker's shared dir collision and create a new dynamic name
    if ($ScriptExists)
    {
        $ScriptName = "pwshcodescript_$([DateTimeOffset]::Now.ToUnixTimeMilliseconds()).ps1"
    }
    try
    {
        # Create script with user's code then run it
        $FinalScript = New-Item -Path $ScriptPath -Name $ScriptName -ItemType "file" -Value $CompleteScript
        # Get all variable names before inner script run
        $StartupVars = Get-Variable | Select-Object -ExpandProperty Name
        ServerLog ([ServerLogLevel]::info) "Powershell loop starting script execute (line count: $BaseCodeLineCount)..." | Out-Null
        & $ScriptPath$ScriptName
        # Get a list of all user created variables after script run
        $UserVars = Get-Variable -Exclude $StartupVars -Scope Global
        $Private:output = $ConsoleOutWriter.ToString()
        $Private:dupOutput = ""
        if ($StdoutDupReader)
        {
            $dupOutput = $StdoutDupReader.ReadToEnd()
        }
        if ($output)
        {
            if ($dupOutput)
            {
                $output += "`n$dupOutput"
            }
        }
        else
        {
            $output = $dupOutput
        }
        if ($output)
        {
            SendStdTextTo $Env:_PWSH_STDOUT_HANDLE "note" $output
        }
        $output = $ConsoleErrWriter.ToString()
        $Private:dupOutput = ""
        if ($StderrDupReader)
        {
            $dupOutput = $StderrDupReader.ReadToEnd()
            if ($dupOutput)
            {
                $dupOutput = "Stderr native: $dupOutput"
            }
        }
        if ($output)
        {
            $output = "Stderr: $output"
            if ($dupOutput)
            {
                $output += "`n$dupOutput"
            }
        }
        else
        {
            $output = $dupOutput
        }
        if ($output)
        {
            SendStdTextTo $Env:_PWSH_STDERR_HANDLE "warning" $output
        }
    }
    catch
    {
        # The string version of error + stack trace since sometimes it is not provided in error body
        $StackTrace = $PSItem.ScriptStackTrace
        $LooperFileName = $PSCommandPath
        $ExceptionBody = $PSItem.ToString() + "`nStack Trace: `n$StackTrace"
        #Regexes to find all cases of line errors, pwsh produces 2 versions of errors
        $Regex1 = "(?i).*line[\s:](\d+)"
        $Regex2 = "(?i)at \S+:(\d+) char:"
        # Find matches for regexes
        $Matches1 = ($ExceptionBody | Select-String -Pattern $Regex1 -AllMatches).Matches
        $Matches2 = ($ExceptionBody | Select-String -Pattern $Regex2 -AllMatches).Matches
        foreach ($Match in $Matches1)
        {
            # Skip line errors that contain the looper file name
            if ($Match.Groups -And $Match.Groups[0] -imatch $LooperFileName)
            {
                continue
            }
            # if match exists convert the captured groups (line numbers) to INTs
            $LineNumber = $Match | ForEach-Object { if ($_.Groups -And $_.Groups[1]) { [convert]::ToInt32($_.Groups[1].Value, 10) } }
            # Will note if the line is in  Object or not, since powershell stack trace won't indicate it
            $Object = ''
            $FinalLineNumber = $LineNumber - $BaseCodeLineCount
            if ($LineNumber - $BaseCodeLineCount -lt 0)
            {
                $Object = ' - In  Class'
                $FinalLineNumber = $LineNumber
            }
            # Replace between the actual line number with updated line number
            $ExceptionBody = $ExceptionBody -replace "(?i)line[\s:]($LineNumber)", "line: $FinalLineNumber$Object"
        }
        foreach ($Match in $Matches2)
        {
            # Skip line errors that contain the looper file name
            if ($Match.Groups -And $Match.Groups[0] -imatch $LooperFileName)
            {
                continue
            }
            # if match exists convert the captured groups (line numbers) to INTs
            $LineNumber = $Match | ForEach-Object { if ($_.Groups -And $_.Groups[1]) { [convert]::ToInt32($_.Groups[1].Value, 10) } }
            # Will note if the line is in  Object or not, since powershell stack trace won't indicate it
            $Object = ''
            $FinalLineNumber = $LineNumber - $BaseCodeLineCount
            if ($LineNumber - $BaseCodeLineCount -lt 0)
            {
                $Object = ' - In  Class'
                $FinalLineNumber = $LineNumber
            }
            # Replace between the actual line number with updated line number
            $ExceptionBody = $ExceptionBody -replace "(?i):($LineNumber) char:", " line: $FinalLineNumber$Object char:"
        }
        # Create error entry after digest and send to server
        $ExceptionMessage = @{type = 'exception'; args = @{exception = "$ExceptionBody" } } | ConvertTo-Json -Compress
        $OutputStream.WriteLine($ExceptionMessage)
    }
    # Restore all env variables
    $EnvVars | ForEach-Object { Set-Item "env:$($_.Name)" $_.Value }
    # Delete new variables that script might have introduced
    foreach ($name in $(Get-ChildItem Env:).Name)
    {
        if ($name -notin $EnvVars.Name)
        {
            Remove-Item -Path "Env:$name"
        }
    }
    # Delete all user created variables from inner script run
    foreach ($var in $UserVars)
    {
        Remove-Variable -Name $var.Name -Force -Scope Global -ErrorAction SilentlyContinue
    }
    # Delete script file safetly after execution
    $ScriptExists = [File]::Exists($ScriptPath + $ScriptName)
    if ($ScriptExists)
    {
        Remove-Item $ScriptPath$ScriptName
    }
    # reset output buffers
    $ConsoleOutWriter.GetStringBuilder().Clear() | Out-Null
    $ConsoleErrWriter.GetStringBuilder().Clear() | Out-Null
    # Send script completion status to server
    $OutputStream.WriteLine($(@{ type = 'completed' } | ConvertTo-Json -Compress))
    # if the script running on native powershell then terminate the process after the script executed
    $IsPowerShellNative = $ParsedEntry.native
    if ($IsPowerShellNative)
    {
        break
    }
}
