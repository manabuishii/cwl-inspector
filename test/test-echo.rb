#!/usr/bin/env ruby
# coding: utf-8
require 'yaml'
require 'test/unit'
require_relative '../cwl/inspector'

unless defined? CWL_PATH
  CWL_PATH=File.join(File.dirname(__FILE__), '..', 'examples')
end

class TestEcho < Test::Unit::TestCase
  def setup
    @cwl = File.join(CWL_PATH, 'echo', 'echo.cwl')
    @runtime = {
      'outdir' => File.absolute_path('.'),
      'docdir' => '.',
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

  def test_version
    assert_equal('v1.0', walk(@cwl, '.cwlVersion'))
  end

  def test_id_based_access
    assert_equal('Input string', walk(@cwl, '.inputs.input.label'))
  end

  def test_index_based_access
    assert_equal('Input string', walk(@cwl, '.inputs.0.label'))
  end

  def test_commandline
    assert_equal("docker run -i --read-only --rm --workdir=#{@vardir}/spool/cwl --env=HOME=#{@vardir}/spool/cwl --env=TMPDIR=/tmp --user=#{Process::UID.eid}:#{Process::GID.eid} -v #{Dir.pwd}:#{@vardir}/spool/cwl -v /tmp:/tmp docker/whalesay \"cowsay\"  > #{Dir.pwd}/output",
                 commandline(@cwl, @runtime, parse_inputs(@cwl, {}, @runtime)))
  end

  def test_instantiated_commandline
    assert_equal("docker run -i --read-only --rm --workdir=#{@vardir}/spool/cwl --env=HOME=#{@vardir}/spool/cwl --env=TMPDIR=/tmp --user=#{Process::UID.eid}:#{Process::GID.eid} -v #{Dir.pwd}:#{@vardir}/spool/cwl -v /tmp:/tmp docker/whalesay \"cowsay\" \"Hello!\" > #{Dir.pwd}/output",
                 commandline(@cwl, @runtime,
                             parse_inputs(@cwl, { 'input' => 'Hello!' }, @runtime)))
  end

  def test_root_keys
    assert_equal(['baseCommand', 'class', 'cwlVersion', 'id',
                  'inputs', 'outputs', 'requirements', 'stdout', 'successCodes'],
                 keys(@cwl, '.').sort)
  end

  def test_keys
    assert_equal(['input'], keys(@cwl, '.inputs'))
  end
end
