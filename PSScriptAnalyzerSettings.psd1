<#
    PSScriptAnalyzer configuration.

    Each excluded rule is listed with the reason it does not apply here, so the
    exclusions stay reviewable rather than becoming a way to silence findings.
#>
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These scripts are interactive console tools whose output IS the user
        # interface, including colour. Write-Output would pollute the pipeline
        # and break callers that consume a script's return value.
        'PSAvoidUsingWriteHost',

        # The caption.ps1 helper functions close over script-scope parameters
        # rather than taking them as arguments. The analyser cannot see through
        # the closure and reports the parameters as unused; they are used.
        'PSReviewUnusedParameter',

        # Convert-ToTags returns many tags, so the plural reads correctly.
        'PSUseSingularNouns',

        # Remove-CaptionPreamble and Set-CaptionSubject are pure string
        # transforms. They match a state-changing verb pattern but change no
        # state, so -WhatIf / -Confirm would be meaningless.
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
