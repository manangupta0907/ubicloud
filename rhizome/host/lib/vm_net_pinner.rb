# frozen_string_literal: true

require_relative "../../common/lib/util"
require_relative "vm_path"
require "fileutils"

# Pins a cloud-hypervisor VM's virtio-net worker threads to stable host CPUs so
# they stop migrating across cores under load. Runs on the hypervisor host.
class VmNetPinner
  # Matches a virtio-net worker thread's comm, e.g. "_net6_qp0".
  NET_THREAD_RE = /net.*_qp[0-9]/
  # net qp threads are created only when the guest activates virtio-net, which
  # can lag VM process start, so poll for them before giving up.
  THREAD_WAIT_TRIES = 30
  DROPIN_FILE = "10-net-pin.conf"

  def initialize(vm_name, exclude_cpus = "")
    exclude_cpus = exclude_cpus.to_s
    fail "invalid vm name: #{vm_name}" unless /\Avm[0-9a-z]{6}\z/.match?(vm_name)
    fail "invalid exclude cpu list: #{exclude_cpus}" unless /\A[0-9,-]*\z/.match?(exclude_cpus)

    @vm_name = vm_name
    @exclude_cpus = exclude_cpus
  end

  def vp
    @vp ||= VmPath.new(@vm_name)
  end

  def dropin_dir
    vp.systemd_service + ".d"
  end

  # Pin each net worker thread to a stable CPU, round-robin across the targets.
  def pin
    pid = main_pid
    tids = wait_net_thread_ids(pid)
    targets = target_cpus(pid)
    tids.each_with_index do |tid, i|
      r "taskset", "-pc", targets[i % targets.size].to_s, tid.to_s
    end
  end

  # Install a systemd drop-in so the pin re-applies on every VM (re)start, then
  # apply it now.
  def install
    FileUtils.mkdir_p(dropin_dir)
    # "-" keeps a pin failure from failing the VM unit; "+" runs it as root.
    File.write(File.join(dropin_dir, DROPIN_FILE), <<~CONF)
      [Service]
      ExecStartPost=-+#{dropin_command}
    CONF
    r "systemctl daemon-reload"
    pin
  end

  # The cloud-hypervisor comm is truncated to "cloud-hyperviso", so pgrep can't
  # find it; resolve the PID from systemd instead.
  def main_pid
    pid = r("systemctl", "show", "-p", "MainPID", "--value", "#{@vm_name}.service").strip.to_i
    fail "no running process for #{@vm_name}" if pid.zero?

    pid
  end

  def net_thread_ids(pid)
    Dir.glob("/proc/#{pid}/task/*").filter_map do |task|
      comm = File.read(File.join(task, "comm")).chomp
      File.basename(task).to_i if NET_THREAD_RE.match?(comm)
    rescue Errno::ENOENT
      # thread exited between the glob and the read; skip it
      next
    end.sort
  end

  def wait_net_thread_ids(pid)
    THREAD_WAIT_TRIES.times do
      tids = net_thread_ids(pid)
      return tids unless tids.empty?

      sleep 1
    end
    fail "no virtio-net worker threads for #{@vm_name}"
  end

  # The CPUs the VM may run on (its own cgroup-constrained allow list) minus any
  # excluded (host storage) cores.
  def target_cpus(pid)
    allowed = File.read("/proc/#{pid}/status")[/^Cpus_allowed_list:\s+(\S+)/, 1]
    fail "no Cpus_allowed_list for #{@vm_name}" unless allowed

    targets = expand(allowed) - expand(@exclude_cpus)
    fail "empty target cpu set for #{@vm_name}" if targets.empty?

    targets
  end

  def dropin_command
    bin = File.expand_path("../bin/pin-vm-net-threads", __dir__)
    [bin, "pin", @vm_name, @exclude_cpus].reject(&:empty?).join(" ")
  end

  def expand(list)
    list.split(",").flat_map do |part|
      lo, _, hi = part.partition("-")
      hi.empty? ? lo.to_i : (lo.to_i..hi.to_i).to_a
    end
  end
end
