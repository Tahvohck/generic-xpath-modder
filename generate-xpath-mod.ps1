<#
	.SYNOPSIS
		Generates a mod from a set of xpath patches.
	.DESCRIPTION
		Creates mods using rimworld-style xpath patching. Some games are natively
		supported but any XML can be modified by using the "unknown" ModType and
		overriding the default data path. The major difference is the presence of a
		"File" attribute on each patch node to identify the file being patched since
		this is being performed on files instead of a live game database.
		
		Example patch file:
		<Patch File="test.xml">
			<Operation Class="PatchOperationAdd>
				...
			</Operation>
		</Patch>
	.LINK
		https://rimworldwiki.com/wiki/Modding_Tutorials/PatchOperations
#>
param(
	# Open a file-picker window to set a custom data path.
	[switch]$OverrideDataPath,
	# Open a file-picker window to set a custom path to the mod folder (default: current directory)
	[switch]$OverrideModPath,
	# Write unified patch database to file <modPath>/PatchDB.xml. This is provided for debugging.
	[switch]$DumpPatchDB,
	# Remove comments from final file
	[switch]$RemoveComments,
	# Directory prefix for generated files. Will result in the path <mod dir>/<prefix>/<source dir>/<output file>
	[string]$OutputPrefix,
	# Overrides for max-depth table. Format is @{"<filename>" = <max depth>}
	# Please note that setting the depth too deep will probably result in unexpected output.
	# Also, the file name should be in lowercase and include the extension.
	[Hashtable]$PartialCopyDepthOverrides,
	# Type of mod, used to identify the ability to partial patch as well as how to read metafiles.
	# When using "unknown" mode, script will do no validation of mod configuration files.
	[ValidateSet("amodconfig", "unknown", "debug")]
	[String]$ModType = "amodconfig"
)

$BaseFilesDirPath = @{
	amodconfig = "..\..\Settlement Survival_Data\StreamingAssets\zipConfig";
	debug = "..\debug_sample"
}[$ModType]
if ($null -eq $BaseFilesDirPath) { $BaseFilesDirPath = "." }
$ModDirPath = "."

$modifiedFlag = "modified_by_xpath_modder"

# structure is modtype -> filename -> Maximum depth (0 is root node)
# When the script can't find an entry in this database it will copy the whole file after making changes,
# AKA default to a depth of 0
$FilesAllowingPartialCopy = @{
	amodconfig = @{
		"building.xml" = 1
	}
	debug = @{
		"test.xml" = 1
	}
}

###############
# Early-exit traps
class UserExit : Exception {}
class ConfigurationError : Exception {}

trap [UserExit] {
	Write-Host -Fore Red "Exiting early (User-requested)"
	return
}
trap [ConfigurationError] {
	Write-Host -Fore Red "Exiting early (configuration incorrect)"
	return
}
trap [NotImplementedException] {
	Write-Host -Fore Red $_
	return
}


###############
# Internal functions
Add-Type -AssemblyName System.Windows.Forms

function Get-EarlyExit {
	$exit = 0 -eq $Host.UI.PromptForChoice("Choice was invalid or user canceled. Exit program?", "", @("&Yes","&No"), 1)
	if ($exit) {
		throw New-Object UserExit
	}	
}

function Set-CustomFolder {
	$CustomFolderPrompt = [Windows.Forms.FolderBrowserDialog]::new()
	$CustomFolderPrompt.InitialDirectory = $PSScriptRoot
	do {
		$Result = $CustomFolderPrompt.ShowDialog()
		$ready = $Result -eq [Windows.Forms.DialogResult]::OK
		if (!$ready) { Get-EarlyExit }
	} while (!$ready)
	return $CustomFolderPrompt.SelectedPath
}

function Get-AMODConfigData {
	param(
		[Parameter(Mandatory=$true)]
		$folder
	)
	$infoFile = get-ChildItem $folder "AMODConfig.xml" -ea ignore
	if (!$infoFile) {
		Write-Host -Fore Red "Couldn't find mod AMODConfig file. Exiting."
		Write-Host -Fore Red "Make sure you're in the mod file location."
		throw New-Object ConfigurationError
	} else {
		$infoFile = [xml](get-content $infoFile)
		Write-Host -fore Cyan (
			"Mod Name: {0}`nAuthor:   {1}`n" -f 
			($infoFile.UGCItemInfo.Title,$infoFile.UGCItemInfo.Auther)
		)
	}
}

function Perform-PatchOperation {
	param(
		[xml.xmlElement]$patch,
		[xml]$unmodifiedFile
	)
	$Matches = @(Select-XML $patch.xpath $unmodifiedFile | Select -Expand Node)
	Write-Host ("{0,-30}{1}" -f $patch.Class,[Web.HTTPUtility]::HtmlDecode($patch.xpath))
	
	foreach ($match in $Matches) {
		$parent = $match.ParentNode
		$depthNode = $match
		$depth = 0
		while ($depthNode -ne $unmodifiedFile.DocumentElement) {
			$depth++
			$depthNode = $depthNode.ParentNode
		}

		switch ($patch.Class) {
			# Add node as a child to the matched node.
			"PatchOperationAdd" {
				foreach ($child in $patch.value.ChildNodes) {
					# Import the node, flag it for preservation if we're not too deep
					# Adding adds the node at one level deeper.
					$child = $unmodifiedFile.ImportNode($child, 1)
					if (($depth +1 ) -le $MaxDepth) {
						$child.SetAttribute($modifiedFlag, 1)
					}

					# Do patch
					if ($patch.order -and $patch.order.ToLower() -eq "prepend") {
						$match.PrependChild($child) | Out-Null
					} else {
						$match.AppendChild($child) | Out-Null
					}
				}
				break
			}
			# Add node as a sibling to the matched node.
			"PatchOperationInsert" {
				foreach ($child in $patch.value.ChildNodes) {
					# Import the node, flag it for preservation if we're not too deep
					# Insertion is already at the correct depth
					$child = $unmodifiedFile.ImportNode($child, 1)
					if ($depth -le $MaxDepth) {
						$child.SetAttribute($modifiedFlag, 1)
					}

					# Do patch
					if ($patch.order -and $patch.order.ToLower() -eq "append") {
						$parent.InsertAfter($child, $match) | Out-Null
					} else {
						$parent.InsertBefore($child, $match) | Out-Null
					}
				}
				break
			}
			# Remove the matched node.
			"PatchOperationRemove" {
				$parent.RemoveChild($match) | Out-Null
				break
			}
			# Replace the matched node with the first child of <value>
			"PatchOperationReplace" {
				$importNode = $unmodifiedFile.ImportNode($patch.value.ChildNodes[0], 1)
				if ($depth -le $MaxDepth) {
					$importNode.SetAttribute($modifiedFlag, 1)
				}
				$match.ParentNode.ReplaceChild($importNode, $match) | Out-Null
				$match = $importNode	# Set the match to the imported node (because the old one was replaced)
				break
			}
			# Adds an attribute only if it doesn't already exist
			"PatchOperationAttributeAdd" {
				if (!$match.HasAttribute($patch.attribute)) {
					$match.SetAttribute($patch.attribute, $patch.value)
					# Flag for preservation if needed
					if ($depth -le $MaxDepth) {
						$match.SetAttribute($modifiedFlag, 1)
					}
				}
				break
			}
			# Sets an attribute whether it exists or not.
			"PatchOperationAttributeSet" {
				$match.SetAttribute($patch.attribute, $patch.value)
				# Flag for preservation if needed
				if ($depth -le $MaxDepth) {
					$match.SetAttribute($modifiedFlag, 1)
				}
				break
			}
			# Remove an attribute
			"PatchOperationAttributeRemove" {
				$match.RemoveAttribute($patch.attribute)
				# Flag for preservation if needed
				if ($depth -le $MaxDepth) {
					$match.SetAttribute($modifiedFlag, 1)
				}
				break
			}
			default {
				Write-Warning ("Patch type [{0}] not supported." -f $patch.Class)
			}
		}

		# Flag this node's ancestors for preservation into stripped down file
		while ($depth -gt 0) {
			$depth--
			if ($depth -le $MaxDepth) {
				$parent.SetAttribute($modifiedFlag, 1)
			}
			$parent = $parent.ParentNode
		}
	}
	
	if ($Matches.Length -eq 0) {
		Write-Warning "No matches found"
	}
}

###############
# Main code
# Perform overrides
if ($OverrideDataPath) {
	$BaseFilesDirPath = Set-CustomFolder
	Write-Host "Using custom data location"
}

if ($OverrideModPath) {
	$ModDirPath = Set-CustomFolder
	Write-Host "Using custom data location"
}

# Validate directories
$BaseFilesDir = Get-Item $BaseFilesDirPath -ea SilentlyContinue
if ($null -eq $BaseFilesDir) {
	Write-Error "Invalid data directory. Please rerun script with -OverrideDataPath if needed."
	throw New-Object ConfigurationError
}

$ModDir = Get-Item $ModDirPath -ea SilentlyContinue
if ($null -eq $ModDir) {
	Write-Error "Invalid mod directory. Please rerun script with -OverrideModPath if needed."
	throw New-Object ConfigurationError
}

# Simplify display paths if possible
$BaseFilesDirPath = $BaseFilesDir.FullName -replace '.*common\\',''
$ModDirPath = $ModDir.FullName -replace '.*common\\',''

Write-Host -Fore Cyan "Data: [$BaseFilesDirPath]"
Write-Host -Fore Cyan "Mod:  [$ModDirPath]"

# Do mod config validation
switch ($modtype) {
	"debug" {
		break
	}
	"amodconfig" {
		Get-AMODConfigData $ModDir
		break
	}
	"unknown" {
		Write-Host -Fore Yellow (
			"WARNING: Running in 'unknown' mode. Files can still be modified, but no validation is done to confirm " +
			"that the mod is set up correctly."
		)
	}
	default {
		Write-Error "Mod type not supported"
		throw New-Object NotImplementedException
	}
}

# Set up patch database
$PatchDB = New-Object XML
$PatchDBRoot = $PatchDB.AppendChild($PatchDB.CreateElement("PatchDatabase"))

# Set up XMLWriter settings
$WriterSettings = New-Object Xml.XmlWriterSettings -Property @{
	Indent = 1
	IndentChars = "`t"
}

# Fill out patch database
foreach ($file in @(Get-ChildItem $ModDir"/patches" "patch*.xml" -ea SilentlyContinue)) {
	[xml]$Patches = Get-Content $file
	$PatchDBRoot.AppendChild($PatchDB.ImportNode($Patches.Patch, 1)) | Out-Null
}

# Ugly import for old patch format (I should have been copying things from rimworld patching to start with)
if (Get-ChildItem $ModDir "patches.xml") {
	Write-Host "Loading legacy patch file"
	[xml]$Patches = Get-ChildItem $ModDir "patches.xml" | Get-Content
	foreach ($fileNode in $Patches.Patches.File) {
		$importedPatch = $PatchDB.CreateElement("Patch")
		$importedPatch.SetAttribute("File", $fileNode.File)
		$importedPatch.AppendChild($PatchDB.CreateComment(
			" Imported from legacy patch format "
		)) | Out-Null
		$PatchDBRoot.AppendChild(
			$PatchDB.ImportNode($fileNode, 1)
		).PrependChild(
			$PatchDB.CreateComment(" Legacy patch ")
		) | Out-Null
		$PatchDBRoot.AppendChild($importedPatch) | Out-Null
		foreach ($patchNode in $fileNode.patch) {
			# Create Replace Operation tag
			$importedOperation = $importedPatch.AppendChild(
				$PatchDB.CreateElement("Operation")
			)
			$importedOperation.SetAttribute("Class", "PatchOperationReplace")
			# Import the xpath
			$importedOperation.AppendChild($PatchDB.ImportNode(
				$patchNode.GetElementsByTagName("xpath")[0],
				1
			)) | Out-Null
			# Import the value tag (previously newNode), but drop all but the first child.
			$importedOperation.AppendChild($PatchDB.CreateElement(
				"value"
			)).AppendChild($PatchDB.ImportNode(
				$patchNode.newNode.ChildNodes[0], 1
			)) | Out-Null
		}
	}
}

# Build list of what files will be modified so we can iterate over it later
$FilesToModify = (Select-XML "//Patch[@File]" $PatchDB).Node.File
	# Only unique instances of the files to modify
	| Sort-Object -Unique
	# Only patches that actually have a base file to modify
	| Where-Object { Get-ChildItem $BaseFilesDir $_ -ea SilentlyContinue }

foreach ($file in $FilesToModify) {
	[xml]$Unmodified = Get-ChildItem $BaseFilesDir $file | Get-Content

	# Build list of Partial-Copy roots
	if ($null -ne $PartialCopyDepthOverrides) {
		$MaxDepth = $PartialCopyDepthOverrides[$file.ToLower()]
	} else {
		$MaxDepth = $FilesAllowingPartialCopy[$modtype][$file.ToLower()]
	}
	if ($null -eq $MaxDepth) { $MaxDepth = 0 }
	
	# Process all the operations for this file
	$Operations = Select-XML "/PatchDatabase/Patch[@File='$file']/Operation" $PatchDB | Select -Expand Node
	foreach ($op in $Operations) {
		Perform-PatchOperation $op $Unmodified
	}
	
	# Remove any unneeded nodes
	$PruningXPath = [String]::Join("|" ,@(
		0..$MaxDepth | %{("/*" * $_ + "/*[not(@$modifiedFlag)]")}
	))
	foreach ($match in @(Select-XML $PruningXPath $Unmodified)) {
		$match.Node.ParentNode.RemoveChild($match.Node) | Out-Null
	}
	
	# Remove metadata tags
	foreach ($match in @(Select-XML "//*[@$modifiedFlag]" $Unmodified)) {
		$match.Node.RemoveAttribute($modifiedFlag)
	}
	
	if ($RemoveComments) {
		Select-XML "//comment()" $Unmodified | %{
			$_.Node.ParentNode.RemoveChild($_.Node) | Out-Null
		}
	}
	
	$outfile = [IO.Path]::Join($ModDir.FullName, $OutputPrefix, $BaseFilesDir.Name, $file )
	New-Item -Force -Type File $outfile -ea SilentlyContinue | Out-Null
	$writer = [XML.XMLWriter]::Create($outfile, $WriterSettings)
	$Unmodified.Save($writer)
	$writer.Close()
}

if ($DumpPatchDB) {
	#Save database for reference
	$outfile = [IO.Path]::Join($ModDir.FullName, "PatchDB.xml")
	New-Item -Force -Type File $outfile -ea SilentlyContinue | Out-Null
	$writer = [XML.XMLWriter]::Create($outfile, $WriterSettings)
	$PatchDB.Save($writer)
	$writer.Close()
}
