. .\tools\psake\psake_ext.ps1
. .\tools\psake\teamcity.ps1

$framework = '4.0'

function Get-GitVersion {
  return (git log -n1 --pretty=%H)
}

properties {
	# version advertised. also used as the tag name in git.
	$public_version = "0.84.0"

	$source_dir = Resolve-Path ./
	$build_dir = "$source_dir\@build"
	$checkout_dir = [Environment]::GetEnvironmentVariable("teamcity.build.checkoutDir")
	$artifact_dir = if ($checkout_dir.length -gt 0) { "$checkout_dir\@artifacts" } else { "$source_dir\@artifacts" }
	$configuration = "Release"
	$build_number = if ("$env:BUILD_NUMBER".length -gt 0) { "$env:BUILD_NUMBER" } else { "0" }
	$build_vcs_number = if ("$env:BUILD_VCS_NUMBER".length -gt 0) { "$env:BUILD_VCS_NUMBER" } else { Get-GitVersion }
    $version = "$public_version.$build_number"
    $info_version = "$version (rev $build_vcs_number)"
}

task default -depends Compile, RunTests, ZipBinaries, ZipSource, NuGet

task NuGet {
  TeamCity-ReportBuildStart "NuGet"

  exec { & "$source_dir\.nuget\NuGet.exe" pack ""$source_dir\DotNetMigrations.nuspec"" -Verbose -OutputDirectory ""$artifact_dir"" -Properties version=$public_version }

  "@echo off
echo Publish the $public_version package to the NuGet Gallery?
pause
..\.nuget\NuGet.exe push .\DotNetMigrations.$public_version.nupkg
pause" | Out-File $artifact_dir\PublishNuGetPackage.bat -Encoding OEM
}

task ZipBinaries {
    TeamCity-ReportBuildStart "ZipBinaries"
    
	$zip_name = "DotNetMigrations-v" + $public_version + "-BIN.zip"
	
	# zip the build output
    # exclude unit tests and debug symbols
    exec { ./tools/7zip/7za.exe a -tzip `"$artifact_dir\$zip_name`" `"$build_dir\*`" `
           `"-x!*.pdb`" `
           `"-x!*migrate*`" `
           `"-x!*x86*`" `
           `"-x!*amd64*`" `
           `"-x!*Tests*`" `
           `"-x!Moq.*`" `
           `"-x!pnunit.*`" `
           `"-x!System.Data.SqlServerCe.dll`" `
           `"-x!nunit.*`" ` }
    
    TeamCity-PublishArtifact "@artifacts\$zip_name"
    TeamCity-ReportBuildFinish "ZipBinaries"
}

task ZipSource {
    TeamCity-ReportBuildStart "ZipSource"
    
    $zip_name = "DotNetMigrations-v" + $public_version + "-SRC.zip"
    
    # zip the source code
    # exclude the cruft
    exec { ./tools/7zip/7za.exe a -tzip `"$artifact_dir\$zip_name`" `"$source_dir\*`" `
           `"-x!.git`" `
           `"-x!@build`" `
           `"-x!@artifacts`" `
           `"-x!*resharper*`" `
           `"-x!.gitignore`" `
           `"-x!TODO.txt`" `
           `"-xr!*.cache`" `
           `"-xr!*.suo`" `
           `"-xr!*.user`" }
    
    TeamCity-PublishArtifact "@artifacts\$zip_name"
    TeamCity-ReportBuildFinish "ZipSource"
}

task RunTests {
    TeamCity-ReportBuildStart "RunTests"
    
    $nunitLauncher = [Environment]::GetEnvironmentVariable("teamcity.dotnet.nunitlauncher")
       
    # we are excluding tests in the "SqlServer" category
    # since those are integration tests that have a dependency
    # on SQL Server which may not be available
    if ($nunitLauncher -ne $null) {
        # run tests using the TeamCity NUnit runner
        exec { & $nunitLauncher v2.0 x86 NUnit-2.4.8 $build_dir\DotNetMigrations.UnitTests.dll }
    } else {
        # run tests using our own copy of NUnit
        $nunitExe = (Get-ChildItem $source_dir\packages\NUnit.* -Recurse -Include nunit-console.exe).FullName
        exec { & "$nunitExe" $build_dir\DotNetMigrations.UnitTests.dll /labels /xml=$artifact_dir\TestResults.xml } `
            "Oops! Build failed due to some failing tests."
    }
    
    TeamCity-ReportBuildFinish "RunTests"
}

task Compile -depends Init {
    TeamCity-ReportBuildStart "Compile"
  "Updating NuGet packages"
  if (-not(Test-Path $source_dir\packages)) {
    New-Item $source_dir\packages -ItemType directory
  }
  exec { & "$source_dir\.nuget\NuGet.exe" update ""$source_dir\DotNetMigrations.sln"" -Verbose -RepositoryPath ""$source_dir\packages"" }

	"Building version $version for $configuration"
	
	# build the solution
	exec { msbuild ""$source_dir\DotNetMigrations.sln"" /m /nologo /t:Rebuild /p:Configuration=$configuration /p:OutDir=""$build_dir\\"" }
    
    TeamCity-ReportBuildFinish "Compile"
}

task Init -depends Clean {
    TeamCity-ReportBuildStart "Init"
    
	Assert($version.length -gt 0) "No version number was specified."
    
    TeamCity-SetBuildNumber $version

	"Informational Version: $info_version"
    
    $year = [DateTime]::Now.ToString("yyyy")

	Generate-Assembly-Info `
        -File "$source_dir\src\CommonAssemblyInfo.cs" `
        -Title "DotNetMigrations $info_version" `
        -Description "" `
        -Company "" `
        -Product "DotNetMigrations $info_version" `
        -Version $version `
        -InfoVersion $info_version `
        -Copyright "Copyright (c) Joshua Poehls 2007-$year"

	New-Item $build_dir -ItemType directory
    New-Item $artifact_dir -ItemType directory
    
    TeamCity-ReportBuildFinish "Init"
}

task Clean {
    TeamCity-ReportBuildStart "Clean"
    
    if (Test-Path $build_dir) { Remove-Item -Force -Recurse $build_dir }
    if (Test-Path $artifact_dir) { Remove-Item -Force -Recurse $artifact_dir }
    
    TeamCity-ReportBuildFinish "Clean"
}