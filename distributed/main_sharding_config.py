#!/usr/bin/evn python
# -*- coding: utf-8 -*-
"""
description:
author: justbk2015
date: 2021/5/22
modify_records:
    - 2021/5/22 justbk2015 create this file
"""

import os
import sys
import yaml


class PathConf:
    ROOT_PATH = os.path.dirname(os.path.abspath(__file__))

    @classmethod
    def get_default_yaml(cls):
        return os.path.join(cls.ROOT_PATH, "config-sharding_tmp.yaml")

    @classmethod
    def get_src_yaml(cls):
        return os.path.join(cls.ROOT_PATH, "config-sharding_src.yaml")

    @classmethod
    def get_user_input_yaml(cls):
        return os.path.join(cls.ROOT_PATH, "user_input.yaml")

class DataSource:
    DS = []

    @classmethod
    def generate_single_ds(cls, ds_name):
        ds_component = ds_name.split(" ")
        url = cls.generate_url(ds_component[0], ds_component[1], ds_component[2])
        values = {
            "url": url,
            "username": ds_component[3],
            "password": ds_component[4],
            "connectionTimeoutMilliseconds": 30000,
            "idleTimeoutMilliseconds": 60000,
            "maintenanceIntervalMilliseconds": 30000,
            "maxLifetimeMilliseconds": 1800000,
            "maxPoolSize": 4096,
            "minPoolSize": 1
        }
        return values

    @classmethod
    def generate_url(cls, ip, port, database):
        return '{prefix}://{ip}:{port}/{database}{suffix}'.format(prefix='jdbc:opengauss',
                                                                  ip=ip,
                                                                  port=port,
                                                                  database=database,
                                                                  suffix='?serverTimezone=UTC&useSSL=false')


class TableConfigFactory:
    DB_REP = 2
    TB_REP = 1
    TABLES = []

    @classmethod
    def generate_rep_expr(cls, name, column, count):
        if count - 1 == 0 and not name.startswith("ds"):
            return name
        return '{name}_${left}{begin}..{end}{right}'.format(name=name,
                                                            left='{',
                                                            right='}',
                                                            begin=0,
                                                            end=count - 1)

    @classmethod
    def generate_alg_expr(cls, column, count):
        return '{column} % {count}'.format(column=column,
                                           count=count)

    @classmethod
    def generate_alg_name(cls, name, is_table):
        before = 'tb' if is_table else 'ds'
        return '_'.join([before, name, "inline"])

    @classmethod
    def generate_table_def(cls, ds_name, ds_count, ds_column, tb_name, tb_count, tb_column):
        ds_expr = cls.generate_rep_expr(ds_name, ds_column, ds_count)
        tb_expr = cls.generate_rep_expr(tb_name, tb_column, tb_count)

        values = {
            "actualDataNodes": '.'.join([ds_expr, tb_expr]),
            "databaseStrategy": {
                "standard": {
                    "shardingColumn": ds_column,
                    "shardingAlgorithmName": cls.generate_alg_name(tb_name, False)
                }
            }
        }
        if tb_count > 1:
            tableStrategy = {"standard":
                {
                    "shardingColumn": tb_column,
                    "shardingAlgorithmName": cls.generate_alg_name(tb_name, True)
                }
            }
            values["tableStrategy"] = tableStrategy
        return values

    @classmethod
    def generate_alg_def(cls, name, column, count):
        return {
            "props": {
                "algorithm-expression": "{name}_${left}{express}{right}"
                    .format(name=name,
                            express=cls.generate_alg_expr(column, count),
                            left='{',
                            right='}')
            },
            "type": "INLINE"
        }

    @classmethod
    def get_all_defs(cls):
        ds_name = "ds"
        for tb_name, ds_column, ds_count, tb_column, tb_count in cls.TABLES:
            tb_def = cls.generate_table_def(ds_name, ds_count, ds_column,
                                            tb_name, tb_count, tb_column)
            tb_alg = None
            if tb_count > 1:
                tb_alg = cls.generate_alg_def(tb_name, tb_column, tb_count)
            ds_alg = cls.generate_alg_def(ds_name, ds_column, ds_count)
            yield tb_name, tb_def, tb_alg, ds_alg


class Format:
    DATABASE_NAME = "ds"
    DATABASE_EXPR = "${0..1}"
    DATABASE_ALG_EXPR = "${id % 2}"
    TABLE_NAME = "subtest"
    TABLE_EXPR = "${0..10}"
    TABLE_COLUMN = "id"
    TABLE_COLUMN_EXPR = "${id % 100}"

    def __init__(self, table_count):
        self.table_count = table_count

    def format(self):
        prop = self.load()
        user_prop = self.parse_parameter()
        for tb_name, tb_def, tb_alg, ds_alg in TableConfigFactory.get_all_defs():
            ds_alg_name = TableConfigFactory.generate_alg_name(tb_name, False)
            tb_alg_name = TableConfigFactory.generate_alg_name(tb_name, True)
            prop.get('rules').get('tables')[tb_name] = tb_def
            prop.get('rules').get('shardingAlgorithms')[ds_alg_name] = ds_alg
            if tb_alg is not None:
                prop.get('rules').get('shardingAlgorithms')[tb_alg_name] = tb_alg
        label = 0
        for i in range(len(DataSource.DS)):
            ds_name1 = 'ds_' + str(label)
            prop.get('dataSources')[ds_name1] = DataSource.generate_single_ds(DataSource.DS[i])
            label += 1

        self.save(prop)
        self.modified_output()
        return prop

    @classmethod
    def save(cls, prop):
        with open(PathConf.get_default_yaml(), "wt", encoding='utf-8') as f:
            yaml.dump(prop, f)

    @classmethod
    def load(cls):
        with open(PathConf.get_src_yaml(), "rt", encoding='utf-8') as f:
            count = f.read()
            return yaml.load(count)

    @classmethod
    def load_user_input(cls):
        with open(PathConf.get_user_input_yaml(), "rt", encoding='utf-8') as f:
            count = f.read()
            return yaml.load(count)

    @classmethod
    def modified_output(cls):
        file = open(PathConf.get_default_yaml(), "r", encoding='utf-8')
        datafile = file.readlines()
        line_list = []
        i = 0
        while i < len(datafile):
            if 'rules' in datafile[i]:
                line_list.append(datafile[i])
                line_list.append('- !SHARDING\n')
                i += 1
            elif 'test_order' in datafile[i]:
                i += 2
            elif 'database_inline' in datafile[i]:
                i += 4
            else:
                line_list.append(datafile[i])
                i += 1

        file = open(PathConf.get_default_yaml(), "w", encoding='utf-8')
        for line in line_list:
            file.write(line)
        file.close()

    @classmethod
    def parse_parameter(cls):
        prop = cls.load_user_input()
        for ds_name in prop.get('dataSources'):
            DataSource.DS.append(ds_name)
        if (prop.get('tables') is None):
            print("Format error: please input at least one table for sharding.")
            sys.exit()
        for table_name in prop.get('tables'):
            table_list = table_name.split(" ")
            table_list[2] = int(table_list[2])
            table_list[4] = int(table_list[4])
            table_tuple = tuple(table_list)
            TableConfigFactory.TABLES.append(table_tuple)
        return prop

if __name__ == '__main__':
    result = Format(10).format()
    print(result)
