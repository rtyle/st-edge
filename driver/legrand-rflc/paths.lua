local version = _VERSION:match("%d+%.%d+")
package.path = 'package/src/?.lua;package/src/?/init.lua;../../lua_modules/share/lua/' .. version .. '/?.lua;../../lua_modules/share/lua/' .. version .. '/?/init.lua;' .. package.path
package.cpath = '../../lua_modules/lib/lua/' .. version .. '/?.so;' .. package.cpath
