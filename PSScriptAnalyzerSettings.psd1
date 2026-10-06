# PSScriptAnalyzer settings used by CI (build/Invoke-CiLint.ps1) and editors.
#
# Accepted suppressions, with the reason they are accepted:
#
#   PSAvoidUsingPositionalParameters
#       Add-Result is called about 200 times with a fixed positional shape
#       (Area, Item, Status, Value, Details). Naming every argument would
#       double the line length without making the calls clearer. The
#       Recommendation, Kind and Source parameters are named on purpose
#       (a sixth positional argument fails, see the tests).
#
#   PSUseShouldProcessForStateChangingFunctions
#       The script is non-remediating. The functions this rule flags only
#       build strings (New-StatusBadge, New-FindingTable, New-IPUReportHtml,
#       New-AssessmentJsonObject); they change no system state, so a
#       -WhatIf/-Confirm switch would have nothing to protect.
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSAvoidUsingPositionalParameters',
        'PSUseShouldProcessForStateChangingFunctions'
    )
}
