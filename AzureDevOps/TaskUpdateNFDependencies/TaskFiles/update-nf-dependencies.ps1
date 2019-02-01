[CmdletBinding()]
param()

Trace-VstsEnteringInvocation $MyInvocation

Import-Module $PSScriptRoot\ps_modules\VstsTaskSdk

Import-VstsLocStrings "$PSScriptRoot\Task.json"

# Get the inputs
[string]$repositoriesToUpdate = Get-VstsInput -Name RepositoriesToUpdate -Require
[string]$gitHubToken = Get-VstsInput -Name GitHubToken -Require

Write-Debug "repositories to update:`n$repositoriesToUpdate"

# compute authorization header in format "AUTHORIZATION: basic 'encoded token'"
# 'encoded token' is the Base64 of the string "nfbot:personal-token"
$auth = "basic $([System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("nfbot:$gitHubToken"))))"

# because it can take sometime for the package to become available on the NuGet providers
# need to hange here for 5 minutes (5 * 60)
"Waiting 5 minutes to let package process flow in NuGet providers..." | Write-Host
Start-Sleep -Seconds 300 

$librariesToUpdate = $repositoriesToUpdate.Split([environment]::NewLine)

ForEach($library in $librariesToUpdate)
{
    # remove quotes, if any
    $library = $library -replace "'", ""

    "Updating $library" | Write-Host

    # init/reset these
    $updateCount = 0
    $commitMessage = ""
    $prTitle = ""
    $projectPath = ""
    $newBranchName = "develop-nfbot/update-dependencies"

    # working directory is agent temp directory
    Write-Debug "Changing working directory to $env:Agent_TempDirectory"
    cd "$env:Agent_TempDirectory" > $null

    # clone library repo and checkout develop branch
    Write-Debug "Init and featch $library repo"
    git init "$env:Agent_TempDirectory\$library"
    cd "$library" > $null
    git remote add origin https://github.com/nanoframework/$library
    git config gc.auto 0
    git config user.name nfbot
    git config user.email nfbot@users.noreply.github.com
    git -c http.extraheader="AUTHORIZATION: $auth" fetch --progress --depth=1 origin
    git checkout develop

    # done, move to source directory
    cd "source"

    # find solution file in repository
    $solutionFile = (Get-ChildItem -Path ".\" -Include "*.sln" -Recurse)

    # find packages.config
    $packagesConfig = (Get-ChildItem -Path ".\" -Include "packages.config" -Recurse)

    # load packages.config as XML doc
    [xml]$packagesDoc = Get-Content $packagesConfig

    $nodes = $packagesDoc.SelectNodes("*").SelectNodes("*")

    $packageList = @(,@())

    Write-Debug "Building package list to update"

    foreach ($node in $nodes)
    {
        # filter out Nerdbank.GitVersioning package
        if($node.id -notlike "Nerdbank.GitVersioning*")
        {
            Write-Debug "Adding $node.id $node.version"

            if($packageList)
            {
                $packageList += , ($node.id,  $node.version)
            }
            else
            {
                $packageList = , ($node.id,  $node.version)
            }
        }
    }

    if ($packageList.length -gt 0)
    {
        "NuGet packages to update:" | Write-Host
        $packageList | Write-Host

        # restore NuGet packages, need to do this before anything else
        nuget restore $solutionFile[0] -Source https://www.myget.org/F/nanoframework-dev/api/v3/index.json -Source https://api.nuget.org/v3/index.json                

        # rename nfproj files to csproj
        Get-ChildItem -Path ".\" -Include "*.nfproj" -Recurse |
            Foreach-object {
                $OldName = $_.name; 
                $NewName = $_.name -replace 'nfproj','csproj'; 
                Rename-Item  -Path $_.fullname -Newname $NewName; 
            }

        # update all packages
        foreach ($package in $packageList)
        {
            # get package name and target version
            $packageName = $package[0]
            $packageOriginVersion = $package[1]

            # update package, only on the first pass
            if($updatePackageOutput -eq $null)
            {
                Write-Debug "Updating packages"

                if ($env:Build_SourceBranchName -like '*release*' -or $env:Build_SourceBranchName -like '*master*')
                {
                    # don't allow prerelease for release and master branches
                    $updatePackageOutput = nuget update $solutionFile[0].FullName -Source https://api.nuget.org/v3/index.json -Source https://api.nuget.org/v3/index.json
                }
                else
                {
                    # allow prerelease for all others
                    $updatePackageOutput = nuget update $solutionFile[0].FullName -Source https://www.myget.org/F/nanoframework-dev/api/v3/index.json -Source https://api.nuget.org/v3/index.json -PreRelease
                }
            }

            # need to get target version
            # load packages.config as XML doc
            [xml]$packagesDoc = Get-Content $packagesConfig

            $nodes = $packagesDoc.SelectNodes("*").SelectNodes("*")

            foreach ($node in $nodes)
            {
                # find this package
                if($node.id -match $packageName)
                {
                    $packageTargetVersion = $node.version
                }
            }

            # sanity check
            if($packageTargetVersion -eq $packageOriginVersion)
            {
                "Skip update of $packageName because it has the same version as before: $packageOriginVersion."
            }
            else
            {
                "Bumping $packageName from $packageOriginVersion to $packageTargetVersion." | Write-Host -ForegroundColor Cyan                
  
                $updateCount = $updateCount + 1;

                #  find csproj
                $projectPath = (Get-ChildItem -Path ".\" -Include "*.csproj" -Recurse)

                # replace NFMDP_PE_LoadHints
                $filecontent = Get-Content($projectPath)
                attrib $projectPath -r
                $filecontent -replace "($packageName.$packageOriginVersion)", "$packageName.$packageTargetVersion" | Out-File $projectPath -Encoding utf8

                # update nuspec files, if any
                $nuspecFiles = (Get-ChildItem -Path ".\" -Include "*.nuspec" -Recurse)

                foreach ($nuspec in $nuspecFiles)
                {
                    [xml]$nuspecDoc = Get-Content $nuspec

                    $nodes = $nuspecDoc.SelectNodes("*").SelectNodes("*")

                    foreach ($node in $nodes)
                    {
                        if($node.Name -eq "metadata")
                        {
                            foreach ($metadataItem in $node.ChildNodes)
                            {                          
                                if($metadataItem.Name -eq "dependencies")
                                {
                                    foreach ($dependency in $metadataItem.ChildNodes)
                                    {
                                        if($dependency.Attributes["id"].value -eq $packageName)
                                        {
                                            $dependency.Attributes["version"].value = "[$packageTargetVersion]"
                                        }
                                    }
                                }
                            }
                        }
                    }

                    $nuspecDoc.Save($nuspec[0].FullName)
                }

                #  update branch name
                $tempPackageName = $packageName -replace "(nanoFramework.)", ""
                $newBranchName += "/$tempPackageName.$packageTargetVersion"
                
                # build commit message
                $commitMessage += "Bumps $packageName from $packageOriginVersion to $packageTargetVersion.`n"

                # build PR title
                $prTitle = "Bumps $packageName from $packageOriginVersion to $packageTargetVersion"

            }

            #clear 
            $updatePackageOutput = $null
        }

        # rename csproj files back to nfproj
        Get-ChildItem -Path ".\" -Include "*.csproj" -Recurse |
        Foreach-object {
            $OldName = $_.name; 
            $NewName = $_.name -replace 'csproj','nfproj'; 
            Rename-Item  -Path $_.fullname -Newname $NewName; 
            }
        
        if($updateCount -eq 0)
        {
            # something went wrong as no package was updated and it should be at least one
            throw "No packages were updated..."
        }

        # need this line so nfbot flags the PR appropriately
        $commitMessage += "`n[version update]`n`n"

        # better add this warning line               
        $commitMessage += "### :warning: This is an automated update. Merge only after all tests pass. :warning:`n"

        # create branch to perform updates
        git branch $newBranchName
        
        # checkout branch
        git checkout $newBranchName

        # commit changes
        git add -A 2>&1

        # commit message with a different title if one or more dependencies are updated
        if ($updateCount -gt 1)
        {
            git commit -m "Update $updateCount NuGet dependencies ***NO_CI***" -m"$commitMessage"

            # fix PR title
            $prTitle = "Update $updateCount NuGet dependencies"
        }
        else 
        {
            git commit -m "$prTitle ***NO_CI***" -m "$commitMessage"
        }

        git -c http.extraheader="AUTHORIZATION: $auth" push --set-upstream origin $newBranchName --porcelain

        # start PR
        # we are hardcoding to 'develop' branch to have a fixed one
        # this is very important for tags (which don't have branch information)
        # considering that the base branch can be changed at the PR ther is no big deal about this 
        $prRequestBody = @{title="$prTitle";body="$commitMessage";head="$newBranchName";base="develop"} | ConvertTo-Json
        $githubApiEndpoint = "https://api.github.com/repos/nanoframework/$library/pulls"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $headers = @{}
        $headers.Add("Authorization","$auth")
        $headers.Add("Accept","application/vnd.github.symmetra-preview+json")

        try 
        {
            $result = Invoke-RestMethod -Method Post -UserAgent [Microsoft.PowerShell.Commands.PSUserAgent]::InternetExplorer -Uri  $githubApiEndpoint -Header $headers -ContentType "application/json" -Body $prRequestBody
            'Started PR with dependencies update...' | Write-Host -NoNewline
            'OK' | Write-Host -ForegroundColor Green
        }
        catch 
        {
            $result = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($result)
            $reader.BaseStream.Position = 0
            $reader.DiscardBufferedData()
            $responseBody = $reader.ReadToEnd();

            "Error starting PR: $responseBody" | Write-Host -ForegroundColor Red
        }
    }
    else
    {
        # nothing to update???
        "Couldn't find anything to update..." | Write-Host -ForegroundColor Black -BackgroundColor Yellow
    }
}

Trace-VstsLeavingInvocation $MyInvocation
