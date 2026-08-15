-- ops/init.lua -- load every op implementation.
--
-- Order matters only at the end: alias ops share a getter with their target,
-- so they are wired up after every module has registered.

require 'ops.variables'
require 'ops.maths'
require 'ops.pitch'
require 'ops.random_ops'
require 'ops.controlflow'
require 'ops.patterns'
require 'ops.hardware'
require 'ops.timing'
require 'ops.queue'
require 'ops.rhythm'
require 'ops.init_ops'
require 'ops.turtle_ops'
require 'ops.i2c'
require 'ops.ansible'
require 'ops.midi_in'

local maths = require 'ops.maths'
maths.apply()

return require 'ops.registry'
