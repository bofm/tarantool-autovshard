local yaml = require("yaml")

local util = require("autovshard.util")

local M = {}

function M.get_replicaset_params(autovshard_cfg, replicaset_uuid)
    return util.table_get(autovshard_cfg, {"sharding", replicaset_uuid})
end

-- sets master=true in autovshard config in Consul for a given instance_uuid
-- and master=false for all other instance_uuids
function M.promote_to_master(autovshard_cfg, replicaset_uuid, instance_uuid)
    new_cfg = table.deepcopy(autovshard_cfg)
    -- config yaml:
    --
    -- sharding:
    --     cb0e44ec-a468-4bcb-b6ff-341899c87d7c:
    --         replicas:
    --             6dee1389-3984-4744-8ae1-6be55a92f66f:
    --                 master_weight: 10
    --                 switchover_delay: 10
    --                 # master: true
    --                 address: 127.0.0.1:3303
    --                 name: t1
    --
    local replicaset_params = M.get_replicaset_params(autovshard_cfg, replicaset_uuid)
    for replica_uuid, _ in pairs(replicaset_params.replicas) do
        new_cfg["sharding"][replicaset_uuid]["replicas"][replica_uuid]["master"] =
            replica_uuid == instance_uuid
    end
    return new_cfg
end

function M.set_instance_read_only(cfg, instance_uuid)
    local new_cfg = table.deepcopy(cfg)
    local changed = false
    for rs_uuid, rs in pairs(cfg.sharding) do
        for rs_param, rs_param_value in pairs(rs) do
            if rs_param == "replicas" then
                for replica_uuid, replica_params in pairs(rs_param_value) do
                    if replica_uuid == instance_uuid and replica_params.master then
                        new_cfg["sharding"][rs_uuid]["replicas"][replica_uuid]["master"] = false
                        changed = true
                    end
                end
            end
        end
    end
    return changed, new_cfg
end

function M.get_instance_params(autovshard_cfg, instance_uuid)
    for _, rs in pairs(autovshard_cfg.sharding) do
        for rs_param, rs_param_value in pairs(rs) do
            if rs_param == "replicas" then
                for replica_uuid, instance_params in pairs(rs_param_value) do
                    if replica_uuid == instance_uuid then return instance_params end
                end
            end
        end
    end
end

function M.get_master_weight(autovshard_cfg, instance_uuid)
    local params = M.get_instance_params(autovshard_cfg, instance_uuid)
    return params and params.master_weight or 0
end

function M.get_switchover_delay(autovshard_cfg, instance_uuid)
    local params = M.get_instance_params(autovshard_cfg, instance_uuid)
    return params and params.switchover_delay
end

function M.is_master(autovshard_cfg, instance_uuid)
    local params = M.get_instance_params(autovshard_cfg, instance_uuid)
    return params ~= nil and params.master == true
end

function M.master_count(autovshard_cfg, replicaset_uuid)
    local rs = autovshard_cfg.sharding[replicaset_uuid]
    if not rs or not rs.replicas then return 0 end
    local master_count = 0
    for _, replica_params in pairs(rs.replicas) do
        if replica_params.master == true then --
            master_count = master_count + 1
        end
    end
    return master_count
end

---make_vshard_config
---@param autovshard_cfg table
---@param login string
---@param password string
---@param box_cfg table
---@return table
function M.make_vshard_config(autovshard_cfg, login, password, box_cfg)
    local cfg = table.deepcopy(box_cfg)
    autovshard_cfg = table.deepcopy(autovshard_cfg)
    local sharding = autovshard_cfg.sharding
    -- sharding:
    --     cb0e44ec-a468-4bcb-b6ff-341899c87d7c:
    --         replicas:
    --             6dee1389-3984-4744-8ae1-6be55a92f66f:
    --                 master_weight: 10
    --                 switchover_delay: 10
    --                 # master: true
    --                 address: 127.0.0.1:3303
    --                 name: t1
    autovshard_cfg.sharding = nil
    util.table_update(cfg, autovshard_cfg)
    cfg.sharding = {}
    for rs_uuid, rs in pairs(sharding) do
        for rs_param, rs_param_value in pairs(rs) do
            if rs_param == "replicas" then
                for replica_uuid, replica in pairs(rs_param_value) do
                    for replica_param, replica_param_value in pairs(replica) do
                        if replica_param == "address" then
                            util.table_set(cfg.sharding, {rs_uuid, rs_param, replica_uuid, "uri"},
                                           string.format("%s:%s@%s", login, password,
                                                         replica_param_value))
                        elseif replica_param == "switchover_delay" then
                            -- Skip. This is an autovshard parameter. Not relevant for vshard.
                        elseif replica_param == "master_weight" then
                            -- Skip. This is an autovshard parameter. Not relevant for vshard.
                        else
                            util.table_set(cfg.sharding,
                                           {rs_uuid, rs_param, replica_uuid, replica_param},
                                           replica_param_value)
                        end
                    end
                    if replica_uuid == cfg.instance_uuid then
                        cfg.replicaset_uuid = rs_uuid
                    end
                end
            else
                util.table_set(cfg.sharding, {rs_uuid, rs_param}, rs_param_value)
            end
        end
    end
    return cfg
end

M.decode = yaml.decode
M.encode = util.yaml_encode_pretty_mapping

return M
