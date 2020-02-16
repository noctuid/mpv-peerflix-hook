-- based off https://gist.github.com/ekisu/bba287693830055a6bad90081c1ad4e2
-- TODO prefetch if next in playlist?

-- peerflix will automatically choose a different port, but there's not a great
-- way to actually determine what port it picked, so explicitly set it

local settings = {
   kill_peerflix = true,
   remove_files = true,
   peerflix_directory = "/tmp/torrent-stream"
}

(require "mp.options").read_options(settings, "peerflix-hook")


-- on success, os.execute returns 0 on lua 5.1 and true on 5.2
local success_values = {}
success_values[0] = true
success_values[true] = true

function cmd_succeeds(cmd)
   return success_values[os.execute(cmd)]
end

function port_is_open(port)
   return not cmd_succeeds("lsof -i :" .. port .. " &> /dev/null")
end

function get_open_port()
   if not port then
      port = 8888
   end
   while not port_is_open(port) do
      port = port + 1
   end
   return port
end

-- alternatives don't seem worth it:
-- https://unix.stackexchange.com/questions/185283/how-do-i-wait-for-a-file-in-the-shell-script
function wait_for_peerflix(port)
   local file = "/tmp/peerflix-" .. port .. ".lock"
   local script = string.format([[
until [ -f %s ]; do
    sleep 1
done
rm %s
]], file, file)
   os.execute("bash -c '" .. script .. "'")
end

-- https://stackoverflow.com/questions/132397/get-back-the-output-of-os-execute-in-lua
function os.capture(cmd, raw)
   local f = assert(io.popen(cmd, 'r'))
   local s = assert(f:read('*a'))
   f:close()
   if raw then return s end
   s = string.gsub(s, '^%s+', '')
   s = string.gsub(s, '%s+$', '')
   -- s = string.gsub(s, '[\n\r]+', ' ')
   return s
end

function get_video_name(port, basename)
   local cmd = "lsof -i :" .. port
      .. " | awk '$1 == \"peerflix\" {print $2; exit}'"
   local peerflix_pid = os.capture(cmd)
   if peerflix_pid == "" then return nil end
   local script = string.format([[
peerflix_dir=%s
pid=%s

files=
count=0
sleep=0.2
max_retries=50
while [ -z "$files" ]; do
    files=$(lsof -a +D "$peerflix_dir" -p "$pid" -Fn)
    if [ $count -gt $max_retries ]; then
        exit 1
    fi
    ((count=count+1))
    sleep "$sleep"
done

echo "$files" | sed -n 's:^n.*/::p'
]], settings.peerflix_directory, peerflix_pid)
   local name = os.capture("bash -c '" .. script .. "'")
   if name == "" then
      return nil
   else
      return name
   end
end

function play_magnet()
   local url = mp.get_property("stream-open-filename")
   if url:find("magnet:") == 1  or url:find("peerflix://") == 1 then
      if url:find("peerflix://") == 1 then
         url = url:sub(12)
      end

      local port = get_open_port()

      mp.msg.info("Starting peerflix on port " .. port)
      -- delete an old lock file that could be hanging around
      os.remove('/tmp/peerflix-' .. port .. ".lock")
      -- utils.subprocess can't execute peerflix without blocking
      -- --remove is broken; https://github.com/mafintosh/peerflix/pull/332
      local peerflix_command = "peerflix --quiet --port "
         .. port .. " --on-listening 'touch /tmp/peerflix-"
         .. port .. ".lock' '" .. url ..  "' > /dev/null &"
      os.execute(peerflix_command)

      mp.msg.info("Waiting for peerflix server")
      wait_for_peerflix(port)

      mp.msg.info("Peerflix server is up")

      local title = get_video_name(port)
      if title then
         mp.msg.info("Setting media title to: " .. title)
         mp.set_property("force-media-title", title)
      end

      mp.set_property("stream-open-filename", "http://localhost:" .. port)
   end
end

function port_is_peerflix_port(port)
   -- could store ports used by peerflix, but user could have called peerflix
   -- directly; check with lsof instead to be certain
   return cmd_succeeds("lsof -i :" .. port .. " | grep --quiet peerflix")
end

function peerflix_cleanup()
   local url = mp.get_property("stream-open-filename")
   local port = url:sub(18)
   if (settings.kill_peerflix and url:find("http://localhost:") == 1
       and port_is_peerflix_port(port)) then
      mp.msg.info("Closing peerflix")
      local cmd = "lsof -i :" .. port
         .. " | awk '$1 == \"peerflix\" {system(\"kill \" $2)}'"
      os.execute(cmd)
      local script = string.format([[
shopt -s nullglob dotglob
videos=(%s/**/*)
if (( ${#videos[*]} )); then
    for video in "${videos[@]}"; do
        if ! lsof "$video" &> /dev/null; then
            rm "$video"
        fi
    done
fi
shopt -u nullglob dotglob
]], settings.peerflix_directory)
      if settings.remove_files then
         mp.msg.info("Removing unused peerflix video files")
         os.execute("bash -c '" .. script .. "'")
      end
   end
end

mp.add_hook("on_load", 50, play_magnet)

mp.add_hook("on_unload", 10, peerflix_cleanup)
