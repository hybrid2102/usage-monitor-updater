@{
    Severity = @('Error', 'Warning')

    ExcludeRules = @(
        # This is a console tool whose output IS the user interface: coloured status
        # lines are the point, and Write-Output/Write-Information would lose the
        # formatting the whole UX depends on.
        'PSAvoidUsingWriteHost',

        # Read-YesNo deliberately prompts on the console instead of using
        # [Parameter(Mandatory)], because it has to degrade to a default answer in
        # non-interactive sessions (Task Scheduler) rather than block forever.
        'PSAvoidUsingUserNameAndPasswordParams',

        # False positive on this file's shape: the script-level parameters are consumed
        # inside functions further down (Invoke-Update, Read-YesNo, Test-DownloadedFile),
        # which the rule does not follow. Verified by running the script - every
        # parameter changes behaviour.
        'PSReviewUnusedParameter'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
