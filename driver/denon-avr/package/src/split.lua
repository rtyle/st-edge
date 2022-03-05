-- http://lua-users.org/wiki/SplitJoin
-- splitByPatternSeparator
return function(str, sep, max)
    sep = '^(.-)'..sep
    local t,n,p, q,r,s = {},1,1, str:find(sep)
    while q and n~=max do
        t[n],n,p = s,n+1,r+1
        q,r,s = str:find(sep,p)
    end
    t[n] = str:sub(p)
    return t
end
