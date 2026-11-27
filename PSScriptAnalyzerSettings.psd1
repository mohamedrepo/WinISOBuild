# PSScriptAnalyzerSettings.psd1
# Settings used by the CI lint job (.github/workflows/ci.yml).
#
# The toolchain is a console/GUI toolkit: Write-Host is its user interface, the
# phase functions are long-lived state changers rather than cmdlets, and MD5 is
# written to the ISO sidecar on purpose. Those stylistic defaults would bury a
# real finding in hundreds of expected ones, so this file gates on the rules
# that catch defects: aliases, Invoke-Expression, positional parameters, global
# variables, null comparisons, plain-text secrets and Windows PowerShell 5.1
# syntax compatibility.
#
# Deliberately not enabled (with the reason):
#   PSAvoidUsingWriteHost                       - Write-Host is the CLI output
#   PSAvoidUsingEmptyCatchBlock                 - best-effort cleanup paths
#   PSUseShouldProcessForStateChangingFunctions - phase functions, not cmdlets
#   PSUseSingularNouns / PSUseApprovedVerbs     - established public names
#   PSReviewUnusedParameter                     - parameters kept for the GUI
#   PSAvoidAssignmentToAutomaticVariable        - $args/$input style in helpers
#   PSUseDeclaredVarsMoreThanAssignments        - deliberate bookkeeping
#   PSAvoidUsingBrokenHashAlgorithms            - MD5 sidecar is by design
#   PSAvoidUsingPlainTextForPassword            - unattend.xml needs the literal
#   PSAvoidUsingComputerNameHardcoded           - flags the LAB01 test fixtures

@{
    IncludeRules = @(
        'PSAvoidUsingCmdletAliases'
        'PSAvoidUsingInvokeExpression'
        'PSAvoidUsingPositionalParameters'
        'PSAvoidGlobalVars'
        'PSPossibleIncorrectComparisonWithNull'
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSUseCompatibleSyntax'
    )

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
