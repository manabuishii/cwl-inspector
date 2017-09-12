# cwl-inspector
[![Build Status](https://travis-ci.org/tom-tan/cwl-inspector.svg?branch=master)](https://travis-ci.org/tom-tan/cwl-inspector)

cwl-inspector provides a handy way to inspect properties of tools or workflows written in Common Workflow Language

# Requirements
- Ruby 2.4.1 or later

# Running examples

Input:
```console
$ cat echo.cwl
class: CommandLineTool
cwlVersion: v1.0
id: echo_cwl
baseCommand:
  - cowsay
inputs:
  - id: input
    type: string?
    inputBinding:
      position: 0
    label: Input string
    doc: This is an input string
outputs:
  - id: output
    type: string?
    outputBinding: {}
requirements:
  - class: DockerRequirement
    dockerPull: docker/whalesay
```

## show a property named 'cwlVersion'
```console
$ ./cwl-inspector.rb echo.cwl cwlVersion
v1.0
```

## show a nested property
```console
$ ./cwl-inspector.rb echo.cwl inputs.input.label
Input string
```

## show the command to run a given cwl file
```console
$ ./cwl-inspector.rb echo.cwl commandline
docker run --rm docker/whalesay cowsay [ $input ]
```
