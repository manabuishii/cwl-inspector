#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl/inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestWorkflow < Test::Unit::TestCase
  def setup
    @cwldir = File.join(CWL_PATH, 'workflow')
    @cwlfile = File.join(@cwldir, '1st-workflow.cwl')
    @runtime = {
      'outdir' => File.absolute_path('tmp'),
      'docdir' => [@cwldir],
      'tmpdir' => '/tmp',
    }
    @vardir = case RUBY_PLATFORM
              when /darwin|mac os/
                '/private/var'
              when /linux/
                '/var'
              else
                raise "Unsupported platform: #{RUBY_PLATFORM}"
              end
  end

  def test_arguments
    cwlfile = File.join(@cwldir, 'arguments.cwl')
    assert_equal("docker run -i --read-only --rm --workdir=#{@vardir}/spool/cwl --env=HOME=#{@vardir}/spool/cwl --env=TMPDIR=/tmp --user=#{Process::UID.eid}:#{Process::GID.eid} -v #{Dir.pwd}/tmp:#{@vardir}/spool/cwl -v /tmp:/tmp -v #{File.expand_path @cwldir}/Foo.java:#{@vardir}/lib/cwl/inputs/Foo.java:ro java:7-jdk \"javac\" \"-d\" \"#{@vardir}/spool/cwl\" \"#{@vardir}/lib/cwl/inputs/Foo.java\"",
                 commandline(cwlfile,
                             @runtime,
                             parse_inputs(cwlfile,
                                          {
                                            'src' => {
                                              'class' => 'File',
                                              'path' => 'Foo.java',
                                            }
                                          },
                                          @runtime['docdir'].first)))
  end

  def test_steps
    cwl = CommonWorkflowLanguage.load_file(@cwlfile)
    assert_equal(['compile', 'untar'], keys(cwl, '.steps').sort)
  end
end
