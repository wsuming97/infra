-- ============================================================
-- PostgreSQL 首次启动时自动执行
-- 为 CPA 和 New API 分别创建用户和数据库
-- ============================================================

-- CPA 数据库
CREATE USER cliproxy WITH PASSWORD 'cliproxy123';
CREATE DATABASE cliproxy OWNER cliproxy;
GRANT ALL PRIVILEGES ON DATABASE cliproxy TO cliproxy;

-- New API 数据库
CREATE USER newapi WITH PASSWORD 'newapi123';
CREATE DATABASE newapi OWNER newapi;
GRANT ALL PRIVILEGES ON DATABASE newapi TO newapi;
