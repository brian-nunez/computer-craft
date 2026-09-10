-- A deliberately impure module, used only to prove that the purity sandbox
-- would notice. If this file ever stops failing, the sandbox has stopped
-- protecting anything and the purity test is worthless.
local handle = fs.open("/somewhere", "r")
return handle
