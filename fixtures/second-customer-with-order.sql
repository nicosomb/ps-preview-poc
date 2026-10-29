-- A second customer, Marie MARTIN, with one order, cloned from John DOE's first order.
-- With John DOE alone, a grid filter that returns every row cannot be told apart from
-- one that matches John: Marie makes the counts differ.

CREATE TEMPORARY TABLE tmp_customer AS SELECT * FROM PREFIX_customer WHERE id_customer = 1;
UPDATE tmp_customer SET id_customer = 0, firstname = 'Marie', lastname = 'MARTIN',
  email = 'marie.martin@example.com', secure_key = MD5('marie.martin'), date_add = NOW(), date_upd = NOW();
INSERT INTO PREFIX_customer SELECT * FROM tmp_customer;
SET @id_customer = LAST_INSERT_ID();
INSERT INTO PREFIX_customer_group (id_customer, id_group)
  SELECT @id_customer, id_group FROM PREFIX_customer_group WHERE id_customer = 1;

CREATE TEMPORARY TABLE tmp_address AS
  SELECT * FROM PREFIX_address WHERE id_customer = 1 ORDER BY id_address LIMIT 1;
UPDATE tmp_address SET id_address = 0, id_customer = @id_customer, firstname = 'Marie', lastname = 'MARTIN',
  alias = 'Marie', date_add = NOW(), date_upd = NOW();
INSERT INTO PREFIX_address SELECT * FROM tmp_address;
SET @id_address = LAST_INSERT_ID();

SET @id_source_order = (SELECT MIN(id_order) FROM PREFIX_orders WHERE id_customer = 1);
CREATE TEMPORARY TABLE tmp_order AS SELECT * FROM PREFIX_orders WHERE id_order = @id_source_order;
UPDATE tmp_order SET id_order = 0, id_customer = @id_customer, id_address_delivery = @id_address,
  id_address_invoice = @id_address, reference = 'QAMARTIN1', secure_key = MD5('marie.martin'),
  date_add = NOW(), date_upd = NOW();
INSERT INTO PREFIX_orders SELECT * FROM tmp_order;
SET @id_order = LAST_INSERT_ID();

CREATE TEMPORARY TABLE tmp_order_detail AS SELECT * FROM PREFIX_order_detail WHERE id_order = @id_source_order;
UPDATE tmp_order_detail SET id_order_detail = 0, id_order = @id_order;
INSERT INTO PREFIX_order_detail SELECT * FROM tmp_order_detail;

INSERT INTO PREFIX_order_history (id_employee, id_order, id_order_state, date_add)
  SELECT 0, @id_order, current_state, NOW() FROM PREFIX_orders WHERE id_order = @id_order;
