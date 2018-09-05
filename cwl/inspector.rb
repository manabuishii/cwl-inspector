#!/usr/bin/env ruby
# coding: utf-8

#
# Copyright (c) 2017 Tomoya Tanjo
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
require 'etc'
require 'optparse'
require_relative 'parser'

def keys(file, path, default=[])
  obj = walk(file, path, nil)
  if obj.instance_of?(Array)
    obj.keys
  else
    obj ? obj.keys : default
  end
end

def get_requirement(cwl, req, default = nil)
  walk(cwl, ".requirements.#{req}",
       walk(cwl, ".hints.#{req}", default))
end

def docker_requirement(cwl)
  if walk(cwl, '.requirements.DockerRequirement')
    walk(cwl, '.requirements.DockerRequirement')
  elsif walk(cwl, '.hints.DockerRequirement') and system('which docker > /dev/null')
    walk(cwl, '.hints.DockerRequirement')
  else
    nil
  end
end

def docker_command(cwl, runtime, inputs)
  dockerReq = docker_requirement(cwl)
  img = if dockerReq
          dockerReq.dockerPull
        end
  if img
    vardir = case RUBY_PLATFORM
             when /darwin|mac os/
               '/private/var'
             when /linux/
               '/var'
             else
               raise "Unsupported platform: #{RUBY_PLATFORM}"
             end
    envReq = get_requirement(cwl, 'EnvVarRequirement')
    envArgs = (envReq ? envReq.envDef : []).map{ |e|
      val = e.envValue.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                inputs, runtime, nil)
      "--env=#{e.envName}='#{val}'"
    }
    workdir = (dockerReq.dockerOutputDirectory or "#{vardir}/spool/cwl")
    cmd = [
      'docker', 'run', '-i', '--read-only', '--rm',
      "--workdir=#{workdir}", "--env=HOME=#{workdir}",
      "--env=TMPDIR=/tmp", *envArgs,
      "--user=#{Process::UID.eid}:#{Process::GID.eid}",
      "-v #{runtime['outdir']}:#{workdir}",
      "-v #{runtime['tmpdir']}:/tmp",
    ]

    replaced_inputs = Hash[
      walk(cwl, '.inputs', []).map{ |v|
        inp, vols = dockerized(inputs[v.id], v.type, vardir)
        cmd.push(*vols)
        [v.id, inp]
      }]
    cmd.push img
    [cmd, replaced_inputs]
  else
    [[], inputs]
  end
end

def dockerized(input, type, vardir)
  case type
  when CWLType
    case type.type
    when 'File', 'Directory'
      container_path = File.join(vardir, 'lib', 'cwl', 'inputs', input.basename)
      vol = ["-v #{input.path}:#{container_path}:ro"]
      ret = input.clone
      ret.path = container_path
      ret.location = 'file://'+ret.path
      [ret, vol]
    else
      [input, []]
    end
  when CommandInputRecordSchema
    vols = []
    kvs = []
    input.fields.each{ |k, v|
      idx = type.fields.find_index{ |f| f.name == k }
      inp, vol = dockerized(v, type.fields[idx], vardir)
      kvs.push([k, inp])
      vols.push(*vols)
    }
    [CWLRecordValue.new(Hash[kvs]), vols]
  when CommandInputEnumSchema
    [input, []]
  when CommandInputArraySchema
    unless input.instance_of? Array
      raise CWLInspectionError, "Array expected but actual: #{input.class}"
    end
    ret = input.map{ |inp|
      dockerized(inp, type.items, vardir)
    }.transpose
    ret.map{ |r| r.flatten }
  else
    input
  end
end

def evaluate_input_binding(cwl, type, binding_, runtime, inputs, self_)
  if type.instance_of? CommandInputUnionSchema
    return evaluate_input_binding(cwl, self_.type, binding_, runtime, inputs, self_.value)
  elsif type.instance_of?(CWLType) and type.type == 'null'
    return
  end
  valueFrom = walk(binding_, '.valueFrom')
  value = nil
  if self_.instance_of? UninstantiatedVariable
    value = valueFrom ? UninstantiatedVariable.new("eval(#{self_.name})") : self_
  elsif valueFrom
    value = valueFrom.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                               inputs, runtime, self_)
    type = guess_type(value)
  else
    value = self_
  end

  shellQuote = if get_requirement(cwl, 'ShellCommandRequirement')
                 walk(binding_, '.shellQuote', true)
               else
                 true
               end

  pre = walk(binding_, '.prefix')
  if value.instance_of? UninstantiatedVariable
    name = shellQuote ? %!"#{self_.name}"! : self_.name
    tmp = pre ? [pre, name] : [name]
    walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
  else
    type = if type.nil? or (type.instance_of?(CWLType) and type.type == 'Any')
             guess_type(value)
           else
             type
           end
    case type
    when CWLType
      case type.type
      when 'null'
        raise CWLInspectionError, "Internal error: this statement should not be executed"
      when 'boolean'
        if value
          pre
        end
      when 'int', 'long', 'float', 'double'
        tmp = pre ? [pre, value] : [value]
        walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
      when 'string'
        val = shellQuote ? %!"#{value}"! : value
        tmp = pre ? [pre, val] : [val]
        walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
      when 'File'
        tmp = pre ? [pre, %!"#{value.path}"!] : [%!"#{value.path}"!]
        walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
      # when 'Directory'
      else
        raise CWLInspectionError, "Unsupported type: #{type}"
      end
    when CommandInputRecordSchema
      raise CWLInspectionError, "Unsupported record type: #{type}"
    when CommandInputEnumSchema
      tmp = pre ? [pre, value] : [value]
      arg1 = walk(binding_, '.separate', true) ? tmp.join(' ') : tmp.join
      arg2 = evaluate_input_binding(cwl, nil, type.inputBinding, runtime, inputs, value)
      [arg1, arg2].join(' ')
    when CommandInputArraySchema
      isep = walk(binding_, '.itemSeparator', nil)
      sep = isep.nil? ? true : walk(binding_, '.separate', true)
      isep = (isep or ' ')

      vals = value.map{ |v|
        evaluate_input_binding(cwl, type.items, type.inputBinding,
                               runtime, inputs, v)
      }
      tmp = pre ? [pre, vals.join(isep)] : [vals.join(isep)]
      sep ? tmp.join(' ') : tmp.join
    when CommandInputUnionSchema
      raise CWLInspectionError, "Internal error: this statement should not be executed"
    else
      raise CWLInspectionError, "Unsupported type: #{type}"
    end
  end
end

def construct_args(cwl, runtime, inputs, self_)
  arr = walk(cwl, '.arguments', []).to_enum.with_index.map{ |body, idx|
    i = walk(body, '.position', 0)
    [[i, idx], evaluate_input_binding(cwl, nil, body, runtime, inputs, nil)]
  }+walk(cwl, '.inputs', []).find_all{ |input|
    type = walk(input, '.type', nil)
    walk(input, '.inputBinding', nil) or
      type.instance_of?(CommandInputRecordSchema) or
      type.instance_of?(CommandInputEnumSchema) or
      type.instance_of?(CommandInputArraySchema)
  }.find_all{ |input|
    not inputs[input.id].nil?
  }.map{ |input|
    i = walk(input, '.inputBinding.position', 0)
    [[i, input.id], evaluate_input_binding(cwl, input.type, input.inputBinding, runtime, inputs, inputs[input.id])]
  }

  arr.sort{ |a, b|
    a0, b0 = a[0], b[0]
    if a0[0] == b0[0]
      a01, b01 = a0[1], b0[1]
      if a01.class == b01.class
        a01 <=> b01
      elsif a01.instance_of? Integer
        -1
      else
        1
      end
    else
      a0[0] <=> b0[0]
    end
  }.map{ |v|
    v[1]
  }.flatten(1)
end

def container_command(cwl, runtime, inputs = nil, self_ = nil, container = :docker)
  case container
  when :docker
    docker_command(cwl, runtime, inputs)
  else
    raise CWLInspectionError, "Unsupported container: #{container}"
  end
end

def commandline(cwl, runtime = {}, inputs = nil, self_ = nil)
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(cwl)
  end
  container, replaced_inputs = container_command(cwl, runtime, inputs, self_, :docker)
  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)

  redirect_in = if walk(cwl, '.stdin')
                  fname = cwl.stdin.evaluate(use_js, inputs, runtime, self_)
                  ['<', fname]
                else
                  []
                end

  redirect_out = if walk(cwl, '.stdout')
                   fname = cwl.stdout.evaluate(use_js, inputs, runtime, self_)
                   ['>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end

  redirect_err = if walk(cwl, '.stderr')
                   fname = cwl.stderr.evaluate(use_js, inputs, runtime, self_)
                   ['2>', File.join(runtime['outdir'], fname)]
                 else
                   []
                 end
  envArgs = if docker_requirement(cwl).nil?
              req = get_requirement(cwl, 'EnvVarRequirement')
              ['env', "HOME='#{runtime['outdir']}'", "TMPDIR='#{runtime['tmpdir']}'"]+(req ? req.envDef : []).map{ |e|
                val = e.envValue.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                          inputs, runtime, nil)
                "#{e.envName}='#{val}'"
              }
            else
              []
            end
  command = [
    *walk(cwl, '.baseCommand', []).map{ |cmd|
      %!"#{cmd}"!
    },
    *construct_args(cwl, runtime, replaced_inputs, self_),
  ]
  shell = case RUBY_PLATFORM
          when /darwin|mac os/
            # sh in macOS has an issue in the `echo` command.
            docker_requirement(cwl).nil? ? '/bin/bash' : '/bin/sh'
          when /linux/
            '/bin/sh'
          else
            raise "Unsupported platform: #{RUBY_PLATFORM}"
          end
  cmd = [
    docker_requirement(cwl).nil? ? 'cd ~' : nil,
    command.join(' ').gsub(/'/) { "'\\''" },
  ].compact.join(' && ')

  [
    *container,
    *envArgs,
    shell, '-c',
    "'#{cmd}'",
    *redirect_in,
    *redirect_out,
    *redirect_err,
  ].compact.join(' ')
end

def eval_runtime(cwl, inputs, outdir, tmpdir)
  runtime = {
    'tmpdir' => tmpdir,
    'outdir' => outdir,
    'docdir' => [
      cwl.instance_of?(String) ? File.dirname(File.expand_path cwl) : Dir.pwd,
      '/usr/share/commonwl',
      '/usr/local/share/commonwl',
      File.join(ENV.fetch('XDG_DATA_HOME',
                          File.join(ENV['HOME'], '.local', 'share')),
                'commonwl'),
    ],
  }

  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)
  reqs = get_requirement(cwl, 'ResourceRequirement')
  can_eval = inputs.values.find_index{ |v| v.instance_of? UninstantiatedVariable }.nil?

  # cores
  coresMin = (reqs and reqs.coresMin)
  if coresMin.instance_of?(Expression)
    coresMin = if can_eval
                 coresMin.evaluate(use_js, inputs, runtime, nil)
               end
  end
  coresMax = (reqs and reqs.coresMax)
  if coresMax.instance_of?(Expression)
    coresMax = if can_eval
                 coresMax.evaluate(use_js, inputs, runtime, nil)
               end
  end
  raise "Invalid ResourceRequirement" if not coresMin.nil? and not coresMax.nil? and coresMax < coresMin
  coresMin = coresMax if coresMin.nil?
  coresMax = coresMin if coresMax.nil?
  ncores = Etc.nprocessors
  runtime['cores'] = if coresMin.nil? and coresMax.nil?
                       ncores
                     else
                       raise "Invalid ResourceRequirement" if ncores < coresMin
                       [ncores, coresMax].min
                     end

  # mem
  ramMin = (reqs and reqs.ramMin)
  if ramMin.instance_of?(Expression)
    ramMin = if can_eval
               ramMin.evaluate(use_js, inputs, runtime, nil)
             end
  end
  ramMax = (reqs and reqs.ramMax)
  if ramMax.instance_of?(Expression)
    ramMax = if can_eval
               ramMax.evaluate(use_js, inputs, runtime, nil)
             end
  end
  raise "Invalid ResourceRequirement" if not ramMin.nil? and not ramMax.nil? and ramMax < ramMin
  ramMin = ramMax if ramMin.nil?
  ramMax = ramMin if ramMax.nil?
  ram = 1024 # default value in cwltool
  runtime['ram'] = if ramMin.nil? and ramMax.nil?
                     ram
                   else
                     raise "Invalid ResourceRequirement" if ram < ramMin
                     [ram, ramMax].min
                   end
  runtime
end

def parse_inputs(cwl, inputs, docdir)
  input_not_required = walk(cwl, '.inputs', []).all?{ |inp|
    (inp.type.class == CommandInputUnionSchema and
      inp.type.types.find_index{ |obj|
       obj.instance_of?(CWLType) and obj.type == 'null'
     }) or not inp.default.nil?
  }
  if inputs.nil? and input_not_required
    inputs = {}
  end
  if inputs.nil?
    Hash[walk(cwl, '.inputs', []).map{ |inp|
           [inp.id, UninstantiatedVariable.new("$#{inp.id}")]
         }]
  else
    invalids = Hash[(inputs.keys-walk(cwl, '.inputs', []).map{ |inp| inp.id }).map{ |k|
                      [k, InvalidVariable.new(k)]
                    }]
    valids = Hash[walk(cwl, '.inputs', []).map{ |inp|
                    [inp.id, parse_object(inp.id, inp.type, inputs.fetch(inp.id, nil),
                                          inp.default, walk(inp, '.inputBinding.loadContents', false),
                                          docdir)]
                  }]
    invalids.merge(valids)
  end
end

def parse_object(id, type, obj, default, loadContents, docdir)
  if type.nil?
    type = guess_type(obj)
  elsif type.instance_of?(CWLType) and type.type == 'Any'
    if obj.nil? and default.nil?
      raise CWLInspectionError, '`Any` type requires non-null object'
    end
    v = (obj or default)
    type = guess_type(v)
  end

  case type
  when CWLType
    case type.type
    when 'null'
      unless obj.nil? and default.nil?
        raise CWLInspectionError, "Invalid null object: #{obj}"
      end
      obj
    when 'boolean'
      obj = obj.nil? ? default : obj
      unless obj == true or obj == false
        raise CWLInspectionError, "Invalid boolean object: #{obj}"
      end
      obj
    when 'int', 'long'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? Integer
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj
    when 'float', 'double'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? Float
        raise CWLInspectionError, "Invalid #{type.type} object: #{obj}"
      end
      obj
    when 'string'
      obj = obj.nil? ? default : obj
      unless obj.instance_of? String
        raise CWLInspectionError, "Invalid string object: #{obj}"
      end
      obj
    when 'File'
      if obj.nil? and default.nil?
        raise CWLInspectionError, "Invalid File object: #{obj}"
      end
      file = obj.nil? ? default : CWLFile.load(obj, docdir, {})
      file.evaluate(docdir, loadContents)
    when 'Directory'
      if obj.nil? and default.nil?
        raise CWLInspectionError, "Invalid Directory object: #{obj}"
      end
      dir = obj.nil? ? default : Directory.load(obj, docdir, {})
      dir.evaluate(docdir, nil)
    end
  when CommandInputUnionSchema
    idx = type.types.find_index{ |t|
      begin
        parse_object(id, t, obj, default, loadContents, docdir)
        true
      rescue CWLInspectionError
        false
      end
    }
    if idx.nil?
      raise CWLInspectionError, "Invalid object: #{obj} of type #{type.to_h}"
    end
    CWLUnionValue.new(type.types[idx],
                      parse_object("#{id}[#{idx}]", type.types[idx], obj, default,
                                   loadContents, docdir))
  when CommandInputRecordSchema, InputRecordSchema
    obj = obj.nil? ? default : obj
    CWLRecordValue.new(Hash[type.fields.map{ |f|
                              [f.name, parse_object(nil, f.type, obj.fetch(f.name, nil), nil,
                                                    loadContents, docdir)]
                            }])
  when CommandInputEnumSchema, InputEnumSchema
    unless obj.instance_of?(String) and type.symbols.include? obj
      raise CWLInspectionError, "Unknown enum value #{obj}: valid values are #{type.symbols}"
    end
    obj.to_sym
  when CommandInputArraySchema, InputArraySchema
    t = type.items
    unless obj.instance_of? Array
      raise CWLInspectionError, "#{input.id} requires array of #{t} type"
    end
    obj.map{ |o|
      parse_object(id, t, o, nil, loadContents, docdir)
    }
  else
    raise CWLInspectionError, "Unsupported type: #{type.class}"
  end
end

def list(cwl, runtime, inputs)
  if cwl.instance_of? String
    cwl = CommonWorkflowLanguage.load_file(file)
  end
  dir = runtime['outdir']

  if File.exist? File.join(dir, 'cwl.output.json')
    json = open(File.join(dir, 'cwl.output.json')) { |f|
      JSON.load(f)
    }
    Hash[json.each.map{ |k, v|
           [k,
            parse_object(k, nil, v, nil, false, runtime['docdir'].first).to_h]
         }]
  else
    Hash[walk(cwl, '.outputs', []).map { |o|
           [o.id, list_(cwl, o, runtime, inputs).to_h]
         }]
  end
end

def list_(cwl, output, runtime, inputs)
  type = output.type
  use_js = get_requirement(cwl, 'InlineJavascriptRequirement', false)

  case type
  when Stdout
    fname = walk(cwl, '.stdout')
    evaled = fname.evaluate(use_js, inputs, runtime, nil)
    dir = runtime['outdir']
    location = if evaled.end_with? '.stdout'
                 File.join(dir, Dir.glob('*.stdout', base: dir).first)
               else
                 File.join(dir, evaled)
               end
    file = CWLFile.load({
                          'class' => 'File',
                          'location' => 'file://'+location,
                        }, runtime['docdir'].first, {})
    File.exist?(location) ? file.evaluate(runtime['docdir'].first, false) : file
  when Stderr
    fname = walk(cwl, '.stderr')
    evaled = fname.evaluate(use_js, inputs, runtime, nil)
    dir = runtime['outdir']
    location = if evaled.end_with? '.stderr'
                 File.join(dir, Dir.glob('*.stderr', base: dir).first)
               else
                 File.join(dir, evaled)
               end
    file = CWLFile.load({
                          'class' => 'File',
                          'location' => 'file://'+location,
                        }, runtime['docdir'].first, {})
    File.exist?(location) ? file.evaluate(runtime['docdir'].first, false) : file
  else
    obj = walk(cwl, ".outputs.#{output.id}")
    type = obj.type
    oBinding = obj.outputBinding
    if oBinding.nil?
      raise CWLInspectionError, 'Not yet supported for outputs without outputBinding'
    end
    loadContents = oBinding.loadContents
    dir = runtime['outdir']
    files = oBinding.glob.map{ |g|
      pats = g.evaluate(use_js, inputs, runtime, nil)
      pats = if pats.instance_of? Array
               pats.join "\0"
             else
               pats
             end
      Dir.glob(pats, base: dir).map{ |f|
        path = File.expand_path(f, dir)
        if File.directory? path
          Directory.load({
                           'class' => 'Directory',
                           'location' => 'file://'+path,
                         }, runtime['docdir'].first, {})
        else
          CWLFile.load({
                         'class' => 'File',
                         'location' => 'file://'+path,
                       }, runtime['docdir'].first, {})
        end
      }
    }.flatten.map{ |f|
      f.evaluate(runtime['docdir'].first, loadContents)
    }.sort_by{ |f| f.basename }
    evaled = if oBinding.outputEval
               oBinding.outputEval.evaluate(use_js, inputs, runtime, files)
             else
               files
             end
    unless obj.secondaryFiles.empty?
      raise CWLInspectionError, '`secondaryFiles` is not supported'
    end
    if type.instance_of?(CWLType) and (type.type == 'File' or
                                       type.type == 'Directory')
      evaled.first
    elsif type.instance_of?(CommandOutputArraySchema) and
         (type.items == 'File' or type.items == 'Directory')
      evaled
    else
      # TODO
      evaled
    end
  end
end

if $0 == __FILE__
  format = :yaml
  inp_obj = nil
  outdir = File.absolute_path Dir.pwd
  tmpdir = '/tmp'
  do_preprocess = true
  opt = OptionParser.new
  opt.banner = "Usage: #{$0} [options] cwl cmd"
  opt.on('-j', '--json', 'Print result in JSON format') {
    format = :json
  }
  opt.on('-y', '--yaml', 'Print result in YAML format (default)') {
    format = :yaml
  }
  opt.on('-i=INPUT', 'Job parameter file for `commandline`') { |inp|
    inp_obj = if inp.end_with? '.json'
                open(inp) { |f|
                  JSON.load(f)
                }
              else
                YAML.load_file(inp)
              end
  }
  opt.on('--outdir=dir') { |dir|
    outdir = File.expand_path dir
  }
  opt.on('--tmpdir=dir') { |dir|
    tmpdir = File.expand_path dir
  }
  opt.on('--without-preprocess') {
    do_preprocess = false
  }
  opt.parse!(ARGV)

  unless ARGV.length == 2
    puts opt.help
    exit
  end

  file, cmd = ARGV
  unless File.exist?(file) or file == '-'
    raise CWLInspectionError, "No such file: #{file}"
  end

  fmt = if format == :yaml
          ->(a) { YAML.dump(a) }
        else
          ->(a) { JSON.dump(a) }
        end

  cwl = if file == '-'
          CommonWorkflowLanguage.load(YAML.load_stream(STDIN).first, Dir.pwd)
        else
          CommonWorkflowLanguage.load_file(file, do_preprocess)
        end
  inputs = parse_inputs(cwl, inp_obj,
                        file == '-' ? Dir.pwd : File.dirname(File.expand_path file))
  runtime = eval_runtime(file, inputs, outdir, tmpdir)

  ret = case cmd
        when /^\..*/
          fmt.call walk(cwl, cmd).to_h
        when /^keys\((\..*)\)$/
          fmt.call keys(cwl, $1)
        when 'commandline'
          case walk(cwl, '.class')
          when 'CommandLineTool'
            commandline(cwl, runtime, inputs)
          when 'ExpressionTool'
            obj = cwl.expression.evaluate(get_requirement(cwl, 'InlineJavascriptRequirement', false),
                                          inputs, runtime)
            "echo '#{JSON.dump(obj).gsub("'"){ "\\'" }}' > #{File.join(runtime['outdir'], 'cwl.output.json')}"
          else
            raise CWLInspectionError, "`commandline` does not support #{walk(cwl, '.class')} class"
          end
        when 'list'
          case walk(cwl, '.class')
          when 'CommandLineTool', 'ExpressionTool'
            fmt.call list(cwl, runtime, inputs)
          else
            raise CWLInspectionError, "`list` does not support #{walk(cwl, '.class')} class"
          end
        else
          raise CWLInspectionError, "Unsupported command: #{cmd}"
        end
  puts ret
end
