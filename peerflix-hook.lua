-- based off https://gist.github.com/ekisu/bba287693830055a6bad90081c1ad4e2
-- TODO prefetch if next in playlist?

-- peerflix will automatically choose a different port, but there's not a great
-- way to actually determine what port it picked, so explicitly set it

used_ports = {}

function port_is_open(port)
   return os.execute("lsof -i :" .. port) ~= 0
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
   os.execute("echo '" .. script .. "' | bash -")
end

function play_magnet()
   local url = mp.get_property("stream-open-filename")
   if (url:find("magnet:") == 1)  or (url:find("peerflix://") == 1) then
      if (url:find("peerflix://") == 1) then
         url = url:sub(12)
      end

      local port = get_open_port()
      table.insert(used_ports, port)

      mp.msg.info("Starting peerflix")
      -- utils.subprocess can't execute peerflix without blocking
      -- --remove is broken; https://github.com/mafintosh/peerflix/pull/332
      local peerflix_command = "peerflix --remove --quiet --port "
         .. port .. " --on-listening 'touch /tmp/peerflix-"
         .. port .. ".lock' " .. url ..  " &"
      os.execute(peerflix_command)

      mp.msg.info("Waiting for server")
      wait_for_peerflix(port)

      mp.msg.info("Server is up")
      mp.set_property("stream-open-filename", "http://localhost:" .. port)
   end
end

function peerflix_cleanup()
   mp.msg.info("cleaningup")
   for _, port in ipairs(used_ports) do
      mp.msg.info(tostring(port))
      cmd = "lsof -i :".. port .. " | awk '$1 == \"peerflix\" {system(\"kill \" $2)}'"
      os.execute(cmd)
   end
end

mp.add_hook("on_load", 50, play_magnet)

mp.add_hook("on_unload", 10, peerflix_cleanup)
