# generic-xpath-modder

Creates mods using rimworld-style xpath patching. Some games are natively
supported but any XML can be modified by using the "unknown" ModType and
overriding the default data path. The major difference is the presence of a
"File" attribute on each patch node to identify the file being patched since
this is being performed on files instead of a live game database.
		
Example patch file:
```
<Patch File="test.xml">
  <Operation Class="PatchOperationAdd">
    ...
  </Operation>
</Patch>
```
