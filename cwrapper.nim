import httpclient, strutils, osproc, os, sequtils, parseopt,json,tables

proc toStringArray(n:JsonNode):seq[string] =
  if n.kind == JsonNodeKind.JArray:
    return n.getElems().map( proc(x:JsonNode):string = x.getStr() )
  else:
    assert(false, "not a jarray node")

proc toStringTable(n:JsonNode):Table[string,string] =
  if n.kind == JsonNodeKind.JObject:
    var keys = n.getFields.keys.toSeq
    var values = n.getFields.values.toSeq
    var strvalues = values.map( proc(x:JsonNode):string = x.getStr() )
    return keys.zip(strvalues).toTable
  else:
    assert(false, "not a jobject node")

proc wrap(module:string, outpath:string, refetch:bool = false)=
  try:
    var content = readFile(module)
    var json = parseJson(content)
    let name = json["name"].getStr()
    let url = json["url"].getStr()
    let dest = getTempDir().joinPath("wrappers").joinPath(name)
    let ppext = "pp"
    let c2nimArgs = json["c2nimArgs"].toStringArray()
    let filesToWrap = json["filesToWrap"].toStringArray()
    let c2nimStatementsAll =  json["c2nimStatementsAll"].toStringArray()
    let c2nimStatementsOnce =  json["c2nimStatementsOnce"].toStringArray()
    let symbolsToReplace =  json["symbolsToReplace"].toStringTable()
    let prefixesToRemove =  json["prefixesToRemove"].toStringArray()
    let unifdefArgs = json["unifdefArgs"].toStringArray()

    createDir(dest)

    var firstFile = true
    var client = newHttpClient()
    for f in filesToWrap:
      var destFileName = dest.joinPath(f)
      var destFilePatch = dest.joinPath(f) & "." & ppext

      if not fileExists(destFileName) or refetch:
        echo "fetching $1 ..." % f
        writeFile(destFileName, client.getContent( url & f ))

      echo "readFile " & destFileName
      var content = readFile(destFileName)
      
      ### dirty hacks
      for k,v in symbolsToReplace.pairs:
        content = content.replace(k, v)
      ###

      var pos = content.find("\n", content.find("#define"))
      var strToInsert = c2nimStatementsAll.join("\n")

      if firstFile:
        strToInsert = c2nimStatementsOnce.join("\n") & strToInsert
        firstFile = false

      content = content[0..pos] & strToInsert & content[pos..^1]

      writeFile(destFilePatch, content)

      if unifdefArgs.len > 0:
        var cmd = "unifdef -m $1 $2" % [unifdefArgs.join(" "), destFilePatch]
        discard execCmd( cmd )
      
    var cmd = "c2nim --out:$1 $2 $3 $4" % [ 
      outpath.joinPath(name) & ".nim", 
      c2nimArgs.join(" ") , 
      prefixesToRemove.map( proc(x:string):string= "--prefix:"&x ).join(" "), 
      filesToWrap.map( proc(f:string):string= dest.joinPath(f) & "." & ppext ).join(" ")]
    echo cmd
    discard execCmd( cmd )

  except:
    quit("exception raised:" & getCurrentExceptionMsg())


when isMainModule:

  var infiles = newSeq[string]()
  var refetch = false
  var outpath:string
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      infiles.add key
    of cmdLongOption, cmdShortOption:
      case key.normalize
      of "h","help":
        stdout.write("""Usage: $1 [options]
Options:
  -h, --help                         show this help
  -o:OUTPATH, --out=OUTPATH          specify output path
  -r, --refetch                      refetch c headers
      """ % getAppFilename().extractFilename())
        quit()
      of "r", "refetch":
        refetch = true
      of "o", "out":
        outpath = val
      else:
        quit("[Error] unknown option: " & key)
    else:
      quit("[Error] unknown kind: " & $kind)
  
  for f in infiles:
    wrap(f,outpath,refetch)
  
  echo "finished"

