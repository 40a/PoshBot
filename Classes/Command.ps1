
# Some custom exceptions dealing with executing commands
class CommandException : Exception {
    CommandException() {}
    CommandException([string]$Message) : base($Message) {}
}
class CommandNotFoundException : CommandException {
    CommandNotFoundException() {}
    CommandNotFoundException([string]$Message) : base($Message) {}
}
class CommandFailed : CommandException {
    CommandFailed() {}
    CommandFailed([string]$Message) : base($Message) {}
}
class CommandDisabled : CommandException {
    CommandDisabled() {}
    CommandDisabled([string]$Message) : base($Message) {}
}
class CommandNotAuthorized : CommandException {
    CommandNotAuthorized() {}
    CommandNotAuthorized([string]$Message) : base($Message) {}
}

# Represent a command that can be executed
class Command {

    # Unique Id of command
    #[string]$Id

    # Unique (to the plugin) name of the command
    [string]$Name

    # The type of message this command is designed to respond to
    # Most of the type, this will be EMPTY so the
    [string]$MessageType

    [string]$Description

    #[string]$Trigger
    [Trigger]$Trigger

    [string]$HelpText

    [bool]$AsJob = $true

    # Script block to execute
    [scriptblock]$ScriptBlock

    # Path to script to execute
    [string]$ScriptPath

    # Fully qualified name of a cmdlet or function in a module to execute
    [string]$ModuleCommand

    [string]$ManifestPath

    [System.Management.Automation.FunctionInfo]$FunctionInfo

    [AccessFilter]$AccessFilter = [AccessFilter]::new()

    [hashtable]$Roles = @{}

    [bool]$Enabled = $true

    # Execute the command in a PowerShell job and return the running job
    [object]Invoke([ParsedCommand]$ParsedCommand, [bool]$InvokeAsJob = $this.AsJob) {

        $ts = [System.Math]::Truncate((Get-Date -Date (Get-Date) -UFormat %s))
        $jobName = "$($this.Name)_$ts"

        # Wrap the command scriptblock so we can splat parameters to it

        # The inner scriptblock gets passed in as a string so we must convert it back to a scriptblock
        # https://www.reddit.com/r/PowerShell/comments/3vwlog/nested_scriptblocks_and_invokecommand/?st=ix0wdgg5&sh=73baa0b2
        # $outer = {
        #     [cmdletbinding()]
        #     param(
        #         [hashtable]$Options
        #     )

        #     $named = $Options.NamedParameters
        #     $pos = $Options.PositionalParameters

        #     if ($Options.IsScriptBlock) {
        #         $sb = [scriptblock]::create($options.ScriptBlock)
        #         & $sb @named @pos
        #     } else {
        #         $inner = [scriptblock]::Create($Options.ScriptBlock)
        #         $ps = $inner.GetPowerShell()
        #         $ps.AddParameters($named) | Out-Null
        #         $ps.AddParameters($pos) | Out-Null
        #         $ps.Invoke()
        #     }
        # }

        $outer = {
            [cmdletbinding()]
            param(
                [hashtable]$Options
            )

            Import-Module -Name $Options.ManifestPath -Scope Local -Force -Verbose:$false

            $named = $Options.NamedParameters
            $pos = $Options.PositionalParameters
            $func = $Options.Function

            & $func @named @pos
        }

        [string]$sb = [string]::Empty
        $options = @{
            NamedParameters = $ParsedCommand.NamedParameters
            PositionalParameters = $ParsedCommand.PositionalParameters
            ManifestPath = $this.ManifestPath
            Function = $this.FunctionInfo
        }
        if ($this.FunctionInfo) {
            $options.FunctionInfo = $this.FunctionInfo
        }

        if ($InvokeAsJob) {
            $jobParams = @{
                Name = $jobName
                ScriptBlock = $outer
                ArgumentList = $options
            }
            return (Start-Job @jobParams)
        } else {
            $ps = [PowerShell]::Create()
            $ps.AddScript($outer) | Out-Null
            $ps.AddArgument($Options)
            $job = $ps.BeginInvoke()
            $done = $job.AsyncWaitHandle.WaitOne()
            $result = $ps.EndInvoke($job)
            return $result
        }

        # if ($this.ModuleCommand) {
        #     $sb = $this.ModuleCommand
        # } elseif ($this.ScriptBlock) {
        #     $sb = $this.ScriptBlock
        #     $options.IsScriptBlock = $true
        # } elseif ($this.ScriptPath) {
        #     $sb = $this.ScriptPath
        # }
        # $options.ScriptBlock = $sb




        # if ($this.AsJob) {

        # } else {

        # }

        # block here until job is complete
        # $done = $job.AsyncWaitHandle.WaitOne()

        # $result = $ps.EndInvoke($job)
        # return $result

        #return Start-Job @jobParams
    }

    [bool]IsAuthorized([string]$User) {
        $authResult = $this.AccessFilter.AuthorizeUser($user)
        return $authResult.Authorized
    }

    [void]Activate() {
        $this.Enabled = $true
    }

    [void]Deactivate() {
        $this.Enabled = $false
    }

    # Add a role
    [void]AddRole([Role]$Role) {
        if (-not $this.Roles.ContainsKey($Role.Id)) {
            $this.Roles.Add($Role.Id, $Role)
        }
    }

    # Remove a role
    [void]RemoveRole([Role]$Role) {
        if ($this.Roles.ContainsKey($Role.Id)) {
            $this.Roles.Remove($Role.Id, $Role)
        }
    }

    # Returns TRUE/FALSE if this command matches a parsed command from the chat network
    [bool]TriggerMatch([ParsedCommand]$ParsedCommand) {
        switch ($this.Trigger.Type) {
            'Command' {
                if ($this.Trigger.Trigger -eq $ParsedCommand.Command) {
                    return $true
                } else {
                    return $false
                }
            }
            'Regex' {
                if ($ParsedCommand.CommandString -match $this.Trigger.Trigger) {
                    return $true
                } else {
                    return $false
                }
            }
        }
         return $false
    }

}

function New-PoshBotCommand {
    [cmdletbinding()]
    param(
        [parameter(Mandatory)]
        [string]$Name,

        [parameter(Mandatory)]
        [Trigger]$Trigger,

        [string]$Description,

        [string]$HelpText,

        [parameter(Mandatory, ParameterSetName = 'scriptblock')]
        [scriptblock]$ScriptBlock,

        [parameter(Mandatory, ParameterSetName = 'scriptpath')]
        [string]$ScriptPath,

        [parameter(Mandatory, ParameterSetName = 'modulecommand')]
        [string]$Module,

        [parameter(Mandatory, ParameterSetName = 'modulecommand')]
        [string]$CommandName,


        [bool]$Enabled = $true
    )

    $command = [Command]::New()
    $command.Name = $Name
    $command.Trigger = $Trigger

    if ($PSBoundParameters.ContainsKey('Description')) {
        $command.Description = $Description
    }

    if ($PSBoundParameters.ContainsKey('HelpText')) {
        $command.HelpText = $HelpText
    }

    switch ($PSCmdlet.ParameterSetName) {
        'scriptblock' {
            $command.ScriptBlock = $ScriptBlock
        }
        'scriptpath' {
            $command.ScriptPath = $ScriptPath
        }
        'modulecommand' {
            $command.ModuleCommand = "$Module\$CommandName"
        }
    }

    $command.Enabled = $Enabled

    return $command
}
